# terraform/modules/iam/main.tf
# ============================================================================
# IAM module — creates OIDC provider + GitHub Actions role.
#
# role_type = "tooling" → ECR push + Terraform state permissions
# role_type = "env"     → ECS deploy + cross-account ECR pull permissions
# ============================================================================

variable "project_name"            { type = string }
variable "account_id"              { type = string }
variable "region"                  { type = string }
variable "github_org"              { type = string }
variable "github_repo"             { type = string }
variable "role_type"               { type = string; default = "env" }  # "tooling" or "env"
variable "ecr_repository_arn"      { type = string; default = "" }
variable "ecs_cluster_arn"         { type = string; default = "" }
variable "task_execution_role_arn" { type = string; default = "" }

# ── OIDC Provider ─────────────────────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]
}

# ── GitHub Actions IAM Role ───────────────────────────────────────────────────
resource "aws_iam_role" "github_actions" {
  name                 = "${var.project_name}-github-actions"
  max_session_duration = 7200

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "GitHubOIDC"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })

  tags = { Name = "${var.project_name}-github-actions" }
}

# ── Permissions policy ────────────────────────────────────────────────────────
resource "aws_iam_policy" "github_actions" {
  name        = "${var.project_name}-github-actions-policy"
  description = "Permissions for GitHub Actions — ${var.role_type} account"

  policy = var.role_type == "tooling" ? jsonencode({
    # ── TOOLING ACCOUNT POLICY ──────────────────────────────────────────────
    # Build + push images, manage Terraform state, manage shared infra
    Version = "2012-10-17"
    Statement = [
      { Sid = "ECR",        Effect = "Allow", Action = ["ecr:*"],                  Resource = "*" },
      { Sid = "S3",         Effect = "Allow", Action = ["s3:*"],                   Resource = "*" },
      { Sid = "DynamoDB",   Effect = "Allow", Action = ["dynamodb:*"],             Resource = "*" },
      { Sid = "IAM",        Effect = "Allow", Action = ["iam:*"],                  Resource = "*" },
      { Sid = "CloudWatch", Effect = "Allow", Action = ["logs:*"],                 Resource = "*" },
      { Sid = "STS",        Effect = "Allow", Action = ["sts:GetCallerIdentity"],  Resource = "*" }
    ]
  }) : jsonencode({
    # ── ENV ACCOUNT POLICY (dev / staging / prod) ───────────────────────────
    # Deploy to ECS, manage infra, pull images from prod ECR cross-account
    Version = "2012-10-17"
    Statement = [
      { Sid = "ECS",        Effect = "Allow", Action = ["ecs:*"],                  Resource = "*" },
      { Sid = "EC2",        Effect = "Allow", Action = ["ec2:*"],                  Resource = "*" },
      { Sid = "ALB",        Effect = "Allow", Action = ["elasticloadbalancing:*"], Resource = "*" },
      { Sid = "ASG",        Effect = "Allow", Action = ["autoscaling:*"],          Resource = "*" },
      { Sid = "IAM",        Effect = "Allow", Action = ["iam:*"],                  Resource = "*" },
      { Sid = "S3",         Effect = "Allow", Action = ["s3:*"],                   Resource = "*" },
      { Sid = "DynamoDB",   Effect = "Allow", Action = ["dynamodb:*"],             Resource = "*" },
      { Sid = "CloudWatch", Effect = "Allow", Action = ["logs:*"],                 Resource = "*" },
      { Sid = "SSM",        Effect = "Allow", Action = ["ssm:*"],                  Resource = "*" },
      { Sid = "STS",        Effect = "Allow", Action = ["sts:GetCallerIdentity"],  Resource = "*" },
      # Cross-account ECR pull from prod account
      {
        Sid    = "ECRCrossAccountPull"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}

output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
