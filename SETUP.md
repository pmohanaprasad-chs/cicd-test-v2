# docs/SETUP.md

# ============================================================================

# SETUP GUIDE — Multi-Account CI/CD Pipeline

# ============================================================================

#

# Architecture:

# prod account → ECR (image build + push) + OIDC + IAM + ECS cluster + VPC + ALB (prod service)

# dev account → ECS cluster + VPC + ALB (dev service)

# staging account → ECS cluster + VPC + ALB (staging service)

#

# Image built ONCE in prod, pulled cross-account by dev/staging.

# Zero hardcoding — everything configured via GitHub vars/secrets.

# ============================================================================

## Step 1 — Bootstrap OIDC in each AWS account

Run this in CloudShell for EACH of the 3 accounts (prod, dev, staging):

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
GH_ORG="your-github-org"        # ← change this
GH_REPO="your-repo-name"        # ← change this
PROJECT_NAME="your-project-name"

# Create OIDC provider
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list \
    6938fd4d98bab03faadb97b34396831e3780aea1 \
    1c58a3a8518e8759bf075b76b750d4f2df264fcd

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# Create GitHub Actions IAM role
aws iam create-role \
  --role-name "${PROJECT_NAME}-github-actions" \
  --max-session-duration 7200 \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Federated": "'"${OIDC_ARN}"'"},
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:'"${GH_ORG}"'/'"${GH_REPO}"':*"
        }
      }
    }]
  }'

# Attach AdministratorAccess temporarily (Terraform will scope this down)
aws iam attach-role-policy \
  --role-name "${PROJECT_NAME}-github-actions" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

echo "✅ IAM role ARN:"
echo "arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT_NAME}-github-actions"
```

Note the role ARN from each account — you'll need it in Step 3.

## Step 2 — Create GitHub environments

In your repo → Settings → Environments, create these 3 environments:

- `dev`
- `staging` (add required reviewer for approval gate)
- `prod` (add required reviewer for approval gate)

## Step 3 — Set GitHub repository variables

Settings → Secrets and variables → Actions → Variables tab

### Repo-level variables (shared across all environments)

```
AWS_REGION          = us-east-1
PROJECT_NAME        = my-app              # used to prefix ALL AWS resources
ECR_REPOSITORY      = my-app              # usually same as PROJECT_NAME
TF_GITHUB_ORG       = your-github-org
TF_GITHUB_REPO      = your-repo-name
```

### Environment variables — prod

```
PROD_IAM_ROLE_ARN     = arn:aws:iam::<prod-account-id>:role/my-app-github-actions
PROD_TF_STATE_BUCKET  = my-app-tfstate-<prod-account-id>
PROD_TF_LOCK_TABLE    = my-app-tf-locks
PROD_ECR_REGISTRY     = <prod-account-id>.dkr.ecr.us-east-1.amazonaws.com
PROD_ECS_CLUSTER      = my-app-cluster
PROD_ECS_SERVICE      = my-app-prod
PROD_ECS_TASK_FAMILY  = my-app-prod
PROD_URL              = http://<prod-alb-dns>/
```

### Environment variables — dev

```
DEV_IAM_ROLE_ARN     = arn:aws:iam::<dev-account-id>:role/my-app-github-actions
DEV_TF_STATE_BUCKET  = my-app-tfstate-<dev-account-id>
DEV_TF_LOCK_TABLE    = my-app-tf-locks
DEV_ECS_CLUSTER      = my-app-cluster
DEV_ECS_SERVICE      = my-app-dev
DEV_ECS_TASK_FAMILY  = my-app-dev
DEV_URL              = http://<dev-alb-dns>/dev
```

> Note: DEV_URL will be empty on first run. After provision-dev completes,
> grab the ALB DNS from Terraform outputs and update this variable.

### Environment variables — staging

```
STAGING_IAM_ROLE_ARN     = arn:aws:iam::<staging-account-id>:role/my-app-github-actions
STAGING_TF_STATE_BUCKET  = my-app-tfstate-<staging-account-id>
STAGING_TF_LOCK_TABLE    = my-app-tf-locks
STAGING_ECS_CLUSTER      = my-app-cluster
STAGING_ECS_SERVICE      = my-app-staging
STAGING_ECS_TASK_FAMILY  = my-app-staging
STAGING_URL              = http://<staging-alb-dns>/staging
```

### Environment variables — prod

```
PROD_IAM_ROLE_ARN     = arn:aws:iam::<prod-account-id>:role/my-app-github-actions
PROD_TF_STATE_BUCKET  = my-app-tfstate-<prod-account-id>
PROD_TF_LOCK_TABLE    = my-app-tf-locks
PROD_ECS_CLUSTER      = my-app-cluster
PROD_ECS_SERVICE      = my-app-prod
PROD_ECS_TASK_FAMILY  = my-app-prod
PROD_URL              = http://<prod-alb-dns>/
```

## Step 4 — Set GitHub secrets

Settings → Secrets and variables → Actions → Secrets tab

### Repo-level secrets (required)

```
GH_PAT              = <fine-grained PAT with Variables + Environments read/write>
```

### Repo-level secrets (optional — only if using Jira integration)

```
JIRA_BASE_URL       = https://your-org.atlassian.net
JIRA_EMAIL          = your-email@example.com
JIRA_API_TOKEN      = <Jira API token>
```

### Repo-level variable (required if using Jira)

```
JIRA_ENABLED        = true
JIRA_PROJECT_KEY    = ABC     # Jira project key, e.g. CSD
```

## Step 5 — First run

1. Push any change to the `dev` branch
2. The `provision-*` jobs run first and create all infrastructure
3. After `provision-dev` completes, grab the ALB DNS from the job summary
   and update `DEV_URL`, `STAGING_URL`, `PROD_URL` in GitHub variables
4. Re-run the pipeline — it will now complete all the way through

> On first run, the ALB URLs won't be set yet so smoke tests will fail.
> That's expected — set the URLs after the first provision and re-run.

## Step 6 — Cross-account ECR pull (first run only)

After the prod account is provisioned, you need to allow the env accounts
to pull from prod ECR. Add the env account IDs to the prod environment:

### Repo-level variable

```
PROD_ENV_ACCOUNT_IDS = ["111111111111","222222222222"]
```

This updates the ECR repository policy on the next `provision-prod` run.

## Pipeline flow

```
push to dev
  ├── provision-dev      (VPC + ECS + ALB in dev account)
  ├── provision-staging  (VPC + ECS + ALB in staging account)
  └── provision-prod     (ECR + VPC + ECS + ALB in prod account)
        ↓ (all provision jobs done)
  build-and-push  (build image → push to prod ECR as sha-<hash>)
        ↓
  deploy-dev      (auto — pulls image from prod ECR, deploys to dev ECS)
        ↓
  ⏸️  staging approval
        ↓
  deploy-staging  (merges dev→staging, deploys to staging ECS)
        ↓
  ⏸️  prod approval
        ↓
  deploy-prod     (merges staging→main, deploys to prod ECS)
```

## Adding a new project

1. Fork/copy this repo
2. Replace app/ with your application code
3. Follow steps 1–5 above with your project's values
4. Push to dev — pipeline handles the rest

No workflow code changes needed. Everything is driven by variables.

## Environment URLs

Each account has its own ALB. URL structure per account:

- dev account: `http://<dev-alb>/dev`
- staging account: `http://<staging-alb>/staging`
- prod account: `http://<prod-alb>/`

Path-based routing within each account is handled by ALB listener rules
and Next.js middleware (which rewrites /dev/_ and /staging/_ → / internally).
