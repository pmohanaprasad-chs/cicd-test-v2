# terraform/main.tf
# Root module – wires together all child modules.

terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }

  # Backend configured via -backend-config flags in CI
  # so no hardcoded values here — works locally and in GitHub Actions
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "Terraform"
      Environment = "shared"
    }
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# ── Networking ────────────────────────────────────────────────────────────────
module "networking" {
  source = "./modules/networking"

  project_name       = var.project_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

# ── ECR ───────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "./modules/ecr"

  repository_name = var.project_name
  account_id      = local.account_id
}

# ── IAM / OIDC ────────────────────────────────────────────────────────────────
module "iam" {
  source = "./modules/iam"

  project_name         = var.project_name
  account_id           = local.account_id
  region               = local.region
  ecr_repository_arn   = module.ecr.repository_arn
  ecs_cluster_arn      = module.ecs.cluster_arn
  github_org           = var.github_org
  github_repo          = var.github_repo
  task_execution_role_arn = module.ecs.task_execution_role_arn
}

# ── ECS cluster + services ────────────────────────────────────────────────────
module "ecs" {
  source = "./modules/ecs"

  project_name           = var.project_name
  account_id             = local.account_id
  region                 = local.region
  vpc_id                 = module.networking.vpc_id
  public_subnet_ids      = module.networking.public_subnet_ids
  private_subnet_ids     = module.networking.private_subnet_ids
  ecr_repository_url     = module.ecr.repository_url
  container_port         = var.container_port
  instance_type          = var.ecs_instance_type
  min_capacity           = var.asg_min_capacity
  max_capacity           = var.asg_max_capacity

  # Per-env desired counts
  dev_desired_count     = var.dev_desired_count
  staging_desired_count = var.staging_desired_count
  prod_desired_count    = var.prod_desired_count

  certificate_arn = var.acm_certificate_arn  # set to "" to skip HTTPS listener
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "alb_dns_name" {
  value = module.ecs.alb_dns_name
}

output "dev_url" {
  value = "http://${module.ecs.alb_dns_name}/dev"
}

output "staging_url" {
  value = "http://${module.ecs.alb_dns_name}/staging"
}

output "prod_url" {
  value = "http://${module.ecs.alb_dns_name}/"
}

output "github_actions_role_arn" {
  value = module.iam.github_actions_role_arn
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_dev" {
  value = module.ecs.service_name_dev
}

output "ecs_service_staging" {
  value = module.ecs.service_name_staging
}

output "ecs_service_prod" {
  value = module.ecs.service_name_prod
}

output "task_family_dev" {
  value = module.ecs.task_family_dev
}

output "task_family_staging" {
  value = module.ecs.task_family_staging
}

output "task_family_prod" {
  value = module.ecs.task_family_prod
}
