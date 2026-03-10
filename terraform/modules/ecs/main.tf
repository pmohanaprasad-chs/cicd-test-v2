# terraform/modules/ecs/main.tf
# Creates:
#   - ECS Cluster with EC2 launch type (Auto Scaling Group + Capacity Provider)
#   - Task Execution IAM Role
#   - Task definitions for dev / staging / prod
#   - ECS Services for dev / staging / prod
#   - Application Load Balancer with path-based routing
#     GET /dev*    → dev target group
#     GET /staging*→ staging target group
#     GET /*       → prod target group

variable "project_name"           { type = string }
variable "account_id"             { type = string }
variable "region"                 { type = string }
variable "vpc_id"                 { type = string }
variable "public_subnet_ids"      { type = list(string) }
variable "private_subnet_ids"     { type = list(string) }
variable "ecr_repository_url"     { type = string }
variable "container_port"         { type = number }
variable "instance_type"          { type = string }
variable "min_capacity"           { type = number }
variable "max_capacity"           { type = number }
variable "dev_desired_count"      { type = number }
variable "staging_desired_count"  { type = number }
variable "prod_desired_count"     { type = number }
variable "certificate_arn"        { type = string }

locals {
  envs = ["dev", "staging", "prod"]
}

# ── Latest ECS-optimised Amazon Linux 2 AMI ───────────────────────────────────
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

# ── Security Groups ───────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Allow HTTP/HTTPS from internet"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.certificate_arn != "" ? [1] : []
    content {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

resource "aws_security_group" "ecs_instances" {
  name        = "${var.project_name}-ecs-sg"
  description = "Allow traffic from ALB to ECS instances"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ecs-sg" }
}

# ── Task Execution Role ───────────────────────────────────────────────────────
resource "aws_iam_role" "task_execution" {
  name = "${var.project_name}-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = toset(local.envs)
  name              = "/ecs/${var.project_name}/${each.key}"
  retention_in_days = 30
}

# ── ALB ───────────────────────────────────────────────────────────────────────
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = false
  tags = { Name = "${var.project_name}-alb" }
}

# Target Groups – one per environment
resource "aws_lb_target_group" "env" {
  for_each = toset(local.envs)

  name        = "${var.project_name}-${each.key}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  deregistration_delay = 30

  health_check {
    path                = "/health.json"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  tags = { Name = "${var.project_name}-${each.key}-tg" }
}

# HTTP Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # Default action → prod
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.env["prod"].arn
  }
}

# Path-based rules: /dev* → dev TG, /staging* → staging TG
resource "aws_lb_listener_rule" "dev" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.env["dev"].arn
  }

  condition {
    path_pattern { values = ["/dev", "/dev/*"] }
  }
}

resource "aws_lb_listener_rule" "staging" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.env["staging"].arn
  }

  condition {
    path_pattern { values = ["/staging", "/staging/*"] }
  }
}

# ── Task Definitions ──────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "env" {
  for_each = toset(local.envs)

  family                   = "${var.project_name}-${each.key}"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = aws_iam_role.task_execution.arn

  cpu    = 256
  memory = 512

  container_definitions = jsonencode([
    {
      name      = "${var.project_name}-app"
      # Placeholder tag; GitHub Actions will update this on each deploy
      image     = "${var.ecr_repository_url}:${each.key}-latest"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = 0       # dynamic port mapping (bridge mode)
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "APP_ENV",    value = each.key },
        { name = "BUILD_SHA",  value = "initial" },
        { name = "PORT",       value = tostring(var.container_port) },
        { name = "HOSTNAME",   value = "0.0.0.0" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/${var.project_name}/${each.key}"
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "app"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "wget -qO- http://localhost:3000/health.json || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])

  tags = {
    Environment = each.key
    ManagedBy   = "Terraform"
  }

  lifecycle {
    # Allow GitHub Actions to update the task definition without Terraform overwriting it
    ignore_changes = [container_definitions]
  }
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "${var.project_name}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.main.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.main.name
    weight            = 1
    base              = 1
  }
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────
resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.project_name}-ecs-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
  }

  vpc_security_group_ids = [aws_security_group.ecs_instances.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" >> /etc/ecs/ecs.config
    echo "ECS_ENABLE_CONTAINER_METADATA=true" >> /etc/ecs/ecs.config
    echo "ECS_CONTAINER_STOP_TIMEOUT=30s" >> /etc/ecs/ecs.config
    EOF
  )

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project_name}-ecs-instance" }
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "ecs" {
  name                      = "${var.project_name}-ecs-asg"
  vpc_zone_identifier       = var.private_subnet_ids
  min_size                  = var.min_capacity
  max_size                  = var.max_capacity
  desired_capacity          = var.min_capacity
  wait_for_capacity_timeout = "0"   # don't block terraform apply waiting for instances

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  protect_from_scale_in = true   # required for managed termination protection

  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }
}

resource "aws_ecs_capacity_provider" "main" {
  name = "${var.project_name}-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 80
    }
  }
}

# ── IAM for EC2 instances in ECS ──────────────────────────────────────────────
resource "aws_iam_role" "ecs_instance" {
  name = "${var.project_name}-ecs-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.project_name}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance.name
}

# ── ECS Services ──────────────────────────────────────────────────────────────
resource "aws_ecs_service" "dev" {
  name            = "${var.project_name}-dev"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.env["dev"].arn
  desired_count   = var.dev_desired_count
  launch_type     = "EC2"

  load_balancer {
    target_group_arn = aws_lb_target_group.env["dev"].arn
    container_name   = "${var.project_name}-app"
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = { Environment = "dev" }
}

resource "aws_ecs_service" "staging" {
  name            = "${var.project_name}-staging"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.env["staging"].arn
  desired_count   = var.staging_desired_count
  launch_type     = "EC2"

  load_balancer {
    target_group_arn = aws_lb_target_group.env["staging"].arn
    container_name   = "${var.project_name}-app"
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = { Environment = "staging" }
}

resource "aws_ecs_service" "prod" {
  name            = "${var.project_name}-prod"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.env["prod"].arn
  desired_count   = var.prod_desired_count
  launch_type     = "EC2"

  load_balancer {
    target_group_arn = aws_lb_target_group.env["prod"].arn
    container_name   = "${var.project_name}-app"
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = { Environment = "prod" }
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_arn"             { value = aws_ecs_cluster.main.arn }
output "cluster_name"            { value = aws_ecs_cluster.main.name }
output "alb_dns_name"            { value = aws_lb.main.dns_name }
output "task_execution_role_arn" { value = aws_iam_role.task_execution.arn }
output "service_name_dev"        { value = aws_ecs_service.dev.name }
output "service_name_staging"    { value = aws_ecs_service.staging.name }
output "service_name_prod"       { value = aws_ecs_service.prod.name }
output "task_family_dev"         { value = aws_ecs_task_definition.env["dev"].family }
output "task_family_staging"     { value = aws_ecs_task_definition.env["staging"].family }
output "task_family_prod"        { value = aws_ecs_task_definition.env["prod"].family }
