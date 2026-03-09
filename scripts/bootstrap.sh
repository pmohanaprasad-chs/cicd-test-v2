#!/usr/bin/env bash
# bootstrap.sh
# ============================================================================
# Run this ONCE locally to set up the prerequisites for GitHub Actions.
# After this script completes, everything else is automated via GitHub Actions.
#
# Prerequisites:
#   - AWS CLI configured with admin credentials (aws configure)
#   - Terraform installed (brew install terraform)
#   - jq installed (brew install jq)
#
# Usage:
#   bash bootstrap.sh
# ============================================================================
set -euo pipefail

# ── Config — edit these ───────────────────────────────────────────────────────
PROJECT="cicd-demo"
REGION="us-east-1"
GITHUB_ORG="coharts-chs"
GITHUB_REPO="cicd-test"
# ─────────────────────────────────────────────────────────────────────────────

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="${PROJECT}-github-actions"
POLICY_NAME="${PROJECT}-github-actions-policy"
STATE_BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"
LOCK_TABLE="${PROJECT}-tf-locks"

echo "============================================"
echo "  Bootstrap CI/CD Prerequisites"
echo "  Account:  ${ACCOUNT_ID}"
echo "  Region:   ${REGION}"
echo "  Org/Repo: ${GITHUB_ORG}/${GITHUB_REPO}"
echo "============================================"
echo ""

# ── Step 1: OIDC Provider ─────────────────────────────────────────────────────
echo "── Step 1: GitHub OIDC Provider ─────────────"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" \
   > /dev/null 2>&1; then
  echo "✅ OIDC provider already exists"
else
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
  echo "✅ Created OIDC provider"
fi

# ── Step 2: IAM Role ──────────────────────────────────────────────────────────
echo ""
echo "── Step 2: IAM Role ─────────────────────────"
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::'"${ACCOUNT_ID}"':oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:'"${GITHUB_ORG}/${GITHUB_REPO}"':*"
      }
    }
  }]
}'

if aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
  echo "✅ IAM role already exists — updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "GitHub Actions OIDC role for ${GITHUB_ORG}/${GITHUB_REPO}"
  echo "✅ Created IAM role: $ROLE_NAME"
fi

# ── Step 3: IAM Policy ────────────────────────────────────────────────────────
echo ""
echo "── Step 3: IAM Policy ───────────────────────"
POLICY_DOC='{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid":"ECR",        "Effect":"Allow","Action":["ecr:*"],                  "Resource":"*"},
    {"Sid":"ECS",        "Effect":"Allow","Action":["ecs:*"],                  "Resource":"*"},
    {"Sid":"EC2",        "Effect":"Allow","Action":["ec2:*"],                  "Resource":"*"},
    {"Sid":"ALB",        "Effect":"Allow","Action":["elasticloadbalancing:*"], "Resource":"*"},
    {"Sid":"ASG",        "Effect":"Allow","Action":["autoscaling:*"],          "Resource":"*"},
    {"Sid":"IAM",        "Effect":"Allow","Action":["iam:*"],                  "Resource":"*"},
    {"Sid":"S3",         "Effect":"Allow","Action":["s3:*"],                   "Resource":"*"},
    {"Sid":"DynamoDB",   "Effect":"Allow","Action":["dynamodb:*"],             "Resource":"*"},
    {"Sid":"CloudWatch", "Effect":"Allow","Action":["logs:*","cloudwatch:*"],  "Resource":"*"},
    {"Sid":"SSM",        "Effect":"Allow","Action":["ssm:*"],                  "Resource":"*"},
    {"Sid":"STS",        "Effect":"Allow","Action":["sts:GetCallerIdentity"],  "Resource":"*"}
  ]
}'

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

if aws iam get-policy --policy-arn "$POLICY_ARN" > /dev/null 2>&1; then
  echo "✅ Policy exists — updating to latest version"
  # Delete all non-default versions first (max 5 allowed)
  OLD_VERSIONS=$(aws iam list-policy-versions \
    --policy-arn "$POLICY_ARN" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
    --output text)
  for V in $OLD_VERSIONS; do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$V"
  done
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "$POLICY_DOC" \
    --set-as-default
else
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "$POLICY_DOC"
  echo "✅ Created policy: $POLICY_NAME"
fi

# Attach policy to role
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN" 2>/dev/null || true
echo "✅ Policy attached to role"

# ── Step 4: S3 State Bucket ───────────────────────────────────────────────────
echo ""
echo "── Step 4: S3 State Bucket ──────────────────"
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  echo "✅ S3 bucket already exists: $STATE_BUCKET"
else
  aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION"
  aws s3api put-bucket-versioning \
    --bucket "$STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption \
    --bucket "$STATE_BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block \
    --bucket "$STATE_BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  echo "✅ Created S3 bucket: $STATE_BUCKET"
fi

# ── Step 5: DynamoDB Lock Table ───────────────────────────────────────────────
echo ""
echo "── Step 5: DynamoDB Lock Table ──────────────"
if aws dynamodb describe-table --table-name "$LOCK_TABLE" > /dev/null 2>&1; then
  echo "✅ DynamoDB table already exists: $LOCK_TABLE"
else
  aws dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
  aws dynamodb wait table-exists --table-name "$LOCK_TABLE"
  echo "✅ Created DynamoDB table: $LOCK_TABLE"
fi

# ── Step 6: Print GitHub variables to set ─────────────────────────────────────
echo ""
echo "============================================"
echo "  ✅ Bootstrap complete!"
echo "============================================"
echo ""
echo "Now set these in GitHub → Settings → Variables:"
echo ""
echo "  REPOSITORY VARIABLES:"
echo "  ┌─────────────────────────┬──────────────────────────────────────────┐"
echo "  │ Variable                │ Value                                    │"
echo "  ├─────────────────────────┼──────────────────────────────────────────┤"
printf "  │ %-23s │ %-40s │\n" "AWS_REGION"       "$REGION"
printf "  │ %-23s │ %-40s │\n" "PROJECT_NAME"     "$PROJECT"
printf "  │ %-23s │ %-40s │\n" "TF_STATE_BUCKET"  "$STATE_BUCKET"
printf "  │ %-23s │ %-40s │\n" "TF_LOCK_TABLE"    "$LOCK_TABLE"
printf "  │ %-23s │ %-40s │\n" "TF_GITHUB_ORG"    "$GITHUB_ORG"
printf "  │ %-23s │ %-40s │\n" "TF_GITHUB_REPO"   "$GITHUB_REPO"
printf "  │ %-23s │ %-40s │\n" "ECR_REPOSITORY"   "$PROJECT"
printf "  │ %-23s │ %-40s │\n" "ECS_CLUSTER"      "${PROJECT}-cluster"
printf "  │ %-23s │ %-40s │\n" "ECS_CONTAINER_NAME" "${PROJECT}-app"
echo "  └─────────────────────────┴──────────────────────────────────────────┘"
echo ""
echo "  ENVIRONMENT VARIABLES (set in dev, staging, prod environments):"
echo "  ┌─────────────────────────┬──────────────────────────────────────────┐"
printf "  │ %-23s │ %-40s │\n" "IAM_ROLE_ARN" \
  "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
printf "  │ %-23s │ %-40s │\n" "ECS_SERVICE_DEV"          "${PROJECT}-dev"
printf "  │ %-23s │ %-40s │\n" "ECS_TASK_FAMILY_DEV"      "${PROJECT}-dev"
printf "  │ %-23s │ %-40s │\n" "ECS_SERVICE_STAGING"      "${PROJECT}-staging"
printf "  │ %-23s │ %-40s │\n" "ECS_TASK_FAMILY_STAGING"  "${PROJECT}-staging"
printf "  │ %-23s │ %-40s │\n" "ECS_SERVICE_PROD"         "${PROJECT}-prod"
printf "  │ %-23s │ %-40s │\n" "ECS_TASK_FAMILY_PROD"     "${PROJECT}-prod"
echo "  │ DEV_URL, STAGING_URL,   │ Set after first deploy (ALB DNS output)  │"
echo "  │ PROD_URL                │                                          │"
echo "  └─────────────────────────┴──────────────────────────────────────────┘"
echo ""
echo "  After setting variables, push to dev branch to trigger the pipeline."
echo "  The pipeline will create ALL remaining infrastructure automatically."
echo ""