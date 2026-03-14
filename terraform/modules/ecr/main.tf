# terraform/modules/ecr/main.tf
# ============================================================================
# ECR repository — lives in the prod account.
# Supports cross-account pull from dev/staging accounts.
# ============================================================================

variable "repository_name"        { type = string }
variable "account_id"             { type = string }
variable "allowed_pull_account_ids" {
  type        = list(string)
  default     = []
  description = "Account IDs allowed to pull images (dev/staging accounts)"
}

resource "aws_ecr_repository" "main" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = var.repository_name }
}

# ── Cross-account pull policy ─────────────────────────────────────────────────
# Allows dev/staging/prod account task execution roles to pull images.
# Only created when allowed_pull_account_ids is non-empty.
resource "aws_ecr_repository_policy" "cross_account_pull" {
  count      = length(var.allowed_pull_account_ids) > 0 ? 1 : 0
  repository = aws_ecr_repository.main.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CrossAccountPull"
        Effect = "Allow"
        Principal = {
          AWS = [
            for account_id in var.allowed_pull_account_ids :
            "arn:aws:iam::${account_id}:root"
          ]
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      }
    ]
  })
}

# ── Lifecycle policy ──────────────────────────────────────────────────────────
resource "aws_ecr_lifecycle_policy" "main" {
  repository = aws_ecr_repository.main.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 50 sha-* tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 50
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "repository_url" { value = aws_ecr_repository.main.repository_url }
output "repository_arn" { value = aws_ecr_repository.main.arn }
output "registry_id"    { value = aws_ecr_repository.main.registry_id }
