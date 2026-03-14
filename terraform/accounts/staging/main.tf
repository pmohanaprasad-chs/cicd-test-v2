# terraform/accounts/dev/main.tf
# ============================================================================
# DEV ACCOUNT
#
# Resources created here:
#   - VPC + subnets + NAT gateway
#   - ECS cluster + EC2 ASG
#   - ALB with path-based routing (/dev → dev service)
#   - ECS service: dev only
#   - IAM roles for ECS tasks
#   - OIDC + github-actions role (for this account's deploy jobs)
#   - CloudWatch log groups
#
# Image is pulled cross-account from prod account ECR.
# ============================================================================

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.50" }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "Terraform"
      Environment = "staging"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  environment = "staging"
}

# ── Networking ────────────────────────────────────────────────────────────────
module "networking" {
  source = "../../modules/networking"

  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

# ── IAM / OIDC ────────────────────────────────────────────────────────────────
module "iam" {
  source = "../../modules/iam"

  project_name = var.project_name
  account_id   = local.account_id
  region       = local.region
  github_org   = var.github_org
  github_repo  = var.github_repo

  role_type    = "env"   # env role: ECS deploy + cross-account ECR pull

  ecr_repository_arn      = var.tooling_ecr_arn
  ecs_cluster_arn         = module.ecs.cluster_arn
  task_execution_role_arn = module.ecs.task_execution_role_arn
}

# ── ECS cluster + service ─────────────────────────────────────────────────────
module "ecs" {
  source = "../../modules/ecs"

  project_name       = var.project_name
  account_id         = local.account_id
  region             = local.region
  environment        = local.environment
  vpc_id             = module.networking.vpc_id
  public_subnet_ids  = module.networking.public_subnet_ids
  private_subnet_ids = module.networking.private_subnet_ids

  # ECR image lives in prod account — referenced by digest at deploy time
  # This placeholder is overridden by the deploy workflow via task def patching
  ecr_repository_url = var.tooling_ecr_url

  container_port = var.container_port
  instance_type  = var.ecs_instance_type
  min_capacity   = var.asg_min_capacity
  max_capacity   = var.asg_max_capacity
  desired_count  = var.desired_count

  # ── Optional ──────────────────────────────────────────────────────────────
  # certificate_arn = var.acm_certificate_arn  # uncomment for HTTPS
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "alb_dns_name"            { value = module.ecs.alb_dns_name }
output "ecs_cluster_name"        { value = module.ecs.cluster_name }
output "ecs_service_staging"         { value = module.ecs.service_name }
output "task_family_staging"         { value = module.ecs.task_family }
output "github_actions_role_arn" { value = module.iam.github_actions_role_arn }
output "ecr_repository_url"      { value = "" }  # ECR is in prod account
