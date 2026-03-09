# Enterprise CI/CD Reference Implementation
## GitHub Actions + AWS ECR + AWS ECS (EC2) + Next.js + Jira

---

## Table of Contents
1. [Architecture Overview](#1-architecture-overview)
2. [File Tree](#2-file-tree)
3. [Variables to Fill](#3-variables-to-fill)
4. [Step-by-Step Setup Checklist](#4-step-by-step-setup-checklist)
5. [Pipeline Flow Explained](#5-pipeline-flow-explained)
6. [Jira Integration Notes](#6-jira-integration-notes)
7. [Rollback Procedures](#7-rollback-procedures)
8. [Scaling to 3 Repos](#8-scaling-to-3-repos)

---

## 1. Architecture Overview

```
                   ┌─────────────────────────────────────────────────┐
                   │              GitHub Repository                   │
                   │  branches: dev / staging / main                  │
                   └───────┬─────────────────────────────────────────┘
                           │ push / PR
                    ┌──────▼──────┐
                    │  ci.yml     │  lint → test → build → docker build
                    └──────┬──────┘  (no push, runs on every PR/push)
                           │
                    merge to dev
                           │
                    ┌──────▼──────────────────────────────────────────┐
                    │  deploy.yml                                      │
                    │                                                  │
                    │  build-and-push                                  │
                    │    └─ docker build + push ECR (sha-<shortsha>)  │
                    │                                                  │
                    │  deploy-dev  (auto)                              │
                    │    ├─ ECS register task def + update service     │
                    │    ├─ smoke test /dev                            │
                    │    └─ Jira → "In QA"                            │
                    │                                                  │
                    │  deploy-staging  (approval required)             │
                    │    ├─ same image digest, no rebuild              │
                    │    ├─ ECS register task def + update service     │
                    │    ├─ smoke test /staging                        │
                    │    └─ Jira → "UAT"                              │
                    │                                                  │
                    │  deploy-prod  (approval required)                │
                    │    ├─ same image digest, no rebuild              │
                    │    ├─ ECS register task def + update service     │
                    │    ├─ smoke test /                               │
                    │    └─ Jira → "Done"                             │
                    └──────────────────────────────────────────────────┘

AWS Infrastructure:
  ECR ──────────────────────────────────────────────────────────────┐
  VPC → public subnets → ALB                                        │
               │ path-based routing                                 │
               ├── /dev/*     → ECS service (dev)  ←── ECS cluster │
               ├── /staging/* → ECS service (staging)              │
               └── /*         → ECS service (prod)                 │
                                  ↑                                 │
                              EC2 ASG ←──────── pulls from ECR ────┘
```

---

## 2. File Tree

```
.
├── .github/
│   └── workflows/
│       ├── ci.yml           # PR/push quality gate
│       └── deploy.yml       # Build + deploy + promote pipeline
│
├── app/                     # Next.js application
│   ├── src/
│   │   ├── app/
│   │   │   ├── layout.tsx
│   │   │   ├── page.tsx
│   │   │   └── api/health/route.ts
│   │   └── __tests__/
│   │       └── page.test.tsx
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── next.config.js
│   ├── package.json
│   └── tsconfig.json
│
├── scripts/
│   ├── smoke-test.sh        # curl smoke tests (HTTP 200 + body check)
│   └── jira-transition.js   # Jira REST API transition script
│
└── terraform/
    ├── main.tf              # Root module
    ├── variables.tf
    ├── terraform.tfvars.example
    └── modules/
        ├── networking/main.tf   # VPC, subnets, IGW, NAT
        ├── ecr/main.tf          # ECR repository + lifecycle policy
        ├── iam/main.tf          # OIDC provider + GitHub Actions role
        └── ecs/main.tf          # Cluster, ASG, services, ALB, task defs
```

---

## 3. Variables to Fill

### Terraform (`terraform/terraform.tfvars`)

| Variable | Example | Description |
|----------|---------|-------------|
| `github_org` | `my-org` | Your GitHub org or username |
| `github_repo` | `cicd-demo` | Repository name |
| `aws_region` | `us-east-1` | AWS region |
| `acm_certificate_arn` | `arn:aws:acm:...` | (Optional) ACM cert for HTTPS |

### GitHub Actions – Repository Variables (`vars.*`)

Set at **repo level** (Settings → Secrets and variables → Variables):

| Variable | Description | Example |
|----------|-------------|---------|
| `AWS_REGION` | AWS region | `us-east-1` |
| `ECR_REPOSITORY` | ECR repo name | `cicd-demo` |
| `ECS_CLUSTER` | ECS cluster name | `cicd-demo-cluster` |
| `ECS_CONTAINER_NAME` | Container name in task def | `cicd-demo-app` |

Set at **environment level** (Settings → Environments → dev/staging/prod):

| Variable | Environment | Description |
|----------|-------------|-------------|
| `IAM_ROLE_ARN` | dev/staging/prod | GitHub Actions IAM Role ARN (from `terraform output github_actions_role_arn`) |
| `ECS_TASK_FAMILY_DEV` | dev | `cicd-demo-dev` |
| `ECS_TASK_FAMILY_STAGING` | staging | `cicd-demo-staging` |
| `ECS_TASK_FAMILY_PROD` | prod | `cicd-demo-prod` |
| `ECS_SERVICE_DEV` | dev | `cicd-demo-dev` |
| `ECS_SERVICE_STAGING` | staging | `cicd-demo-staging` |
| `ECS_SERVICE_PROD` | prod | `cicd-demo-prod` |
| `DEV_URL` | dev | `http://<ALB_DNS>/dev` |
| `STAGING_URL` | staging | `http://<ALB_DNS>/staging` |
| `PROD_URL` | prod | `http://<ALB_DNS>` |
| `JIRA_TRANSITION_DEV` | dev | Jira transition ID (see §6) |
| `JIRA_TRANSITION_STAGING` | staging | Jira transition ID |
| `JIRA_TRANSITION_PROD` | prod | Jira transition ID |

### GitHub Actions – Repository Secrets (`secrets.*`)

| Secret | Description |
|--------|-------------|
| `JIRA_BASE_URL` | `https://yourorg.atlassian.net` |
| `JIRA_EMAIL` | Atlassian account email |
| `JIRA_API_TOKEN` | Atlassian API token (not password) |

---

## 4. Step-by-Step Setup Checklist

### Phase 1 – AWS Infrastructure

```bash
# 1. Clone this repo
git clone https://github.com/YOUR_ORG/cicd-demo
cd cicd-demo

# 2. Configure AWS CLI
aws configure
# or: export AWS_PROFILE=your-profile

# 3. Create S3 bucket + DynamoDB table for Terraform state (recommended)
aws s3 mb s3://YOUR_TERRAFORM_STATE_BUCKET --region us-east-1
aws dynamodb create-table \
  --table-name YOUR_TERRAFORM_LOCK_TABLE \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# 4. Fill in Terraform variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars

# 5. Init + apply
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# 6. Note the outputs – you'll use these in GitHub
terraform output
```

Expected outputs:
```
alb_dns_name          = "cicd-demo-alb-123456789.us-east-1.elb.amazonaws.com"
ecr_repository_url    = "123456789.dkr.ecr.us-east-1.amazonaws.com/cicd-demo"
github_actions_role_arn = "arn:aws:iam::123456789:role/cicd-demo-github-actions"
ecs_cluster_name      = "cicd-demo-cluster"
ecs_service_dev       = "cicd-demo-dev"
...
```

### Phase 2 – GitHub Repository Setup

```bash
# 1. Create branches
git checkout -b dev && git push -u origin dev
git checkout -b staging && git push -u origin staging
# main is your default branch

# 2. Protect branches (via GitHub UI or gh CLI)
# Settings → Branches → Add branch protection rule for: main, staging, dev
#   ✅ Require pull request reviews before merging
#   ✅ Require status checks to pass (ci / Lint & Test, ci / Next.js Build, ci / Docker Build)
#   ✅ Require branches to be up to date
```

### Phase 3 – GitHub Environments & Secrets

```
Settings → Environments → New environment

Create: dev
  - No reviewers (auto-deploy)
  - Add Variables: IAM_ROLE_ARN, ECS_TASK_FAMILY_DEV, ECS_SERVICE_DEV, DEV_URL,
                   JIRA_TRANSITION_DEV

Create: staging
  - Required reviewers: add 1-2 team members
  - Add Variables: IAM_ROLE_ARN, ECS_TASK_FAMILY_STAGING, ECS_SERVICE_STAGING,
                   STAGING_URL, JIRA_TRANSITION_STAGING

Create: prod
  - Required reviewers: add 1-2 team members
  - Deployment branches: main only
  - Add Variables: IAM_ROLE_ARN, ECS_TASK_FAMILY_PROD, ECS_SERVICE_PROD,
                   PROD_URL, JIRA_TRANSITION_PROD
```

Repository-level variables (Settings → Secrets and variables → Variables):
```
AWS_REGION          = us-east-1
ECR_REPOSITORY      = cicd-demo
ECS_CLUSTER         = cicd-demo-cluster
ECS_CONTAINER_NAME  = cicd-demo-app
```

Repository-level secrets:
```
JIRA_BASE_URL       = https://yourorg.atlassian.net
JIRA_EMAIL          = your@email.com
JIRA_API_TOKEN      = your-atlassian-api-token
```

### Phase 4 – First Deploy

```bash
# 1. Create a feature branch with a Jira key in the name
git checkout dev
git checkout -b feature/ABC-123-initial-setup

# 2. Make a small change to the app
echo "# Change" >> app/README.md
git add . && git commit -m "ABC-123: initial setup"
git push -u origin feature/ABC-123-initial-setup

# 3. Open a PR against dev
# → ci.yml will run: lint, test, build, docker build (no push)

# 4. Merge the PR to dev
# → deploy.yml triggers automatically:
#   build-and-push  →  deploy-dev (automatic)
#   deploy-staging  (waiting for approval)
#   deploy-prod     (waiting for approval)

# 5. Approve staging in GitHub UI
# Actions → Deploy → deploy-staging → Review deployments → Approve

# 6. After staging smoke test passes, approve prod
# Actions → Deploy → deploy-prod → Review deployments → Approve

# 7. Verify
curl http://<ALB_DNS>/dev
curl http://<ALB_DNS>/staging
curl http://<ALB_DNS>/
```

Each response should contain: **Hello from CI/CD**

### Phase 5 – Verify Jira

1. Open your Jira board
2. Find ticket ABC-123
3. After dev deploy: status should be **In QA**
4. After staging deploy: status should be **UAT**
5. After prod deploy: status should be **Done**
6. Each transition adds an automated comment

---

## 5. Pipeline Flow Explained

### Image tagging strategy

```
Build (dev branch):
  sha-a1b2c3d  ← immutable, built once
  dev-latest   ← mutable convenience tag

Promotion to staging:
  Uses sha-a1b2c3d@sha256:<digest>  ← digest is truly immutable
  staging-latest updated

Promotion to prod:
  Same digest: sha256:<digest>
  prod-latest updated
```

**Why digest over tag?** Even `IMMUTABLE` ECR repos allow the same tag to
be pushed again if the manifest differs. Using the digest (`@sha256:...`)
guarantees you're deploying byte-for-byte the same image that passed QA.

### ECS deployment (idempotent)

Each deploy:
1. Downloads the current task definition JSON from ECS
2. `amazon-ecs-render-task-definition` swaps only the `image` field
3. `amazon-ecs-deploy-task-definition` registers a new revision + calls
   `UpdateService` with the new revision
4. Waits for the service to reach steady state (rolling update)
5. ECS deployment circuit breaker auto-rolls back if tasks fail to start

---

## 6. Jira Integration Notes

### Get transition IDs

```bash
# Find the transition IDs for your Jira workflow
curl -s \
  -u "your@email.com:YOUR_API_TOKEN" \
  "https://yourorg.atlassian.net/rest/api/3/issue/ABC-123/transitions" \
  | jq '.transitions[] | {id: .id, name: .name, to: .to.name}'
```

Output example:
```json
{ "id": "21", "name": "Start Progress", "to": "In Progress" }
{ "id": "31", "name": "Send to QA",     "to": "In QA"       }
{ "id": "41", "name": "UAT",            "to": "UAT"         }
{ "id": "51", "name": "Done",           "to": "Done"        }
```

Set in GitHub:
```
JIRA_TRANSITION_DEV     = 31
JIRA_TRANSITION_STAGING = 41
JIRA_TRANSITION_PROD    = 51
```

### Fallback: name-based matching

If `JIRA_TRANSITION_*` vars are **not** set, `jira-transition.js` will
match transitions by the `to.name` field. This is slower (one extra API
call) but avoids hardcoding IDs.

### Jira Automation vs REST API

| | REST API (this impl.) | Jira Automation |
|---|---|---|
| Control | Full — any workflow | Declarative rules only |
| Auth | API token → secure | Jira-managed |
| Latency | ~200ms | 5–30s (async) |
| Cost | Free | Included in Jira Cloud |
| Complexity | Script in repo | UI config in Jira |

**Recommendation:** Use the REST API approach (this implementation) for
precise, deterministic transitions triggered at exact deploy moments.
Use Jira Automation as a supplement (e.g., notify Slack on status change).

---

## 7. Rollback Procedures

### Option A – Redeploy a previous task definition revision

```bash
# List recent task definition revisions
aws ecs list-task-definitions \
  --family-prefix cicd-demo-prod \
  --sort DESC \
  --query 'taskDefinitionArns[:10]' \
  --output text

# Update the service to a specific revision (e.g., revision 42)
aws ecs update-service \
  --cluster cicd-demo-cluster \
  --service cicd-demo-prod \
  --task-definition cicd-demo-prod:42 \
  --region us-east-1

# Wait for stability
aws ecs wait services-stable \
  --cluster cicd-demo-cluster \
  --services cicd-demo-prod
```

### Option B – Retrigger deploy with previous image tag

```bash
# Find the previous sha tag in ECR
aws ecr list-images \
  --repository-name cicd-demo \
  --filter tagStatus=TAGGED \
  --query 'imageIds[*].imageTag' \
  --output text

# Trigger deploy.yml manually with the old tag
# (GitHub Actions → Deploy → Run workflow → input image_tag: sha-<oldsha>)
```

### Option C – ECS deployment circuit breaker (automatic)

The ECS service has `deployment_circuit_breaker { rollback = true }`.
If more than 50% of tasks fail to reach RUNNING state in the 10-minute
window, ECS automatically rolls back to the previous task definition.

---

## 8. Scaling to 3 Repos

To scale this pattern across a platform with 3+ services:

1. **Shared infrastructure repo** — keep Terraform here, parameterise
   `project_name` per service. Each service gets its own ECR repo and
   ECS service but shares the cluster and ALB.

2. **Shared composite actions** — extract the deploy logic into a
   reusable workflow (`.github/workflows/deploy-shared.yml`) in an
   internal GitHub org. Each app repo calls it:
   ```yaml
   jobs:
     deploy:
       uses: my-org/.github/.github/workflows/deploy-shared.yml@main
       with:
         ecr_repository: my-service
         ecs_service_dev: my-service-dev
       secrets: inherit
   ```

3. **Shared smoke test / Jira scripts** — publish `scripts/` as an
   npm package or reference via `actions/checkout` on the shared repo.

4. **Per-environment IAM roles** — each service gets its own OIDC role
   scoped to its ECR repo and ECS services. The trust policy already
   scopes to `repo:org/repo:environment:*`.
