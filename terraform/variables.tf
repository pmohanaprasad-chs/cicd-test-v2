# terraform/variables.tf

variable "aws_region" {
  description = "AWS region to deploy all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used to prefix all resources"
  type        = string
  default     = "cicd-demo"
}

variable "github_org" {
  description = "GitHub organisation or user name (for OIDC trust policy)"
  type        = string
  default     = "pmohanaprasad-chs"
}

variable "github_repo" {
  description = "GitHub repository name (for OIDC trust policy)"
  type        = string
  default     = "cicd-test"
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
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
  default = 3
}

variable "dev_desired_count" {
  type    = number
  default = 1
}

variable "staging_desired_count" {
  type    = number
  default = 1
}

variable "prod_desired_count" {
  type    = number
  default = 2
}

# ── ACM ───────────────────────────────────────────────────────────────────────
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS. Leave empty to use HTTP only."
  type        = string
  default     = ""
}
