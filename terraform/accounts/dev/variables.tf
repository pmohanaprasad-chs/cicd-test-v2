# terraform/accounts/dev/variables.tf

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type = string
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

# ── Prod account references ───────────────────────────────────────────────────
variable "tooling_ecr_url" {
  description = "ECR repository URL in prod account"
  type        = string
  default     = ""
  # Set via GitHub var: PROD_ECR_URL
  # e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-app
}

variable "tooling_ecr_arn" {
  description = "ECR repository ARN in prod account (for IAM cross-account pull)"
  type        = string
  default     = ""
  # Set via GitHub var: PROD_ECR_ARN
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"   # dev uses 10.1.x.x to avoid overlap
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.0.0/24", "10.1.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.10.0/24", "10.1.11.0/24"]
}

# ── ECS ───────────────────────────────────────────────────────────────────────
variable "container_port" {
  type    = number
  default = 3000
}

variable "ecs_instance_type" {
  type    = string
  default = "t3.small"
}

variable "asg_min_capacity" {
  type    = number
  default = 1
}

variable "asg_max_capacity" {
  type    = number
  default = 2
}

variable "desired_count" {
  type    = number
  default = 1
}

# ── Optional ──────────────────────────────────────────────────────────────────
# variable "acm_certificate_arn" {
#   description = "ACM cert ARN for HTTPS. Leave empty for HTTP only."
#   type        = string
#   default     = ""
# }
