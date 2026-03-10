#!/usr/bin/env bash
# tf-import-ci.sh
# ============================================================================
# Runs inside GitHub Actions before terraform plan.
# Imports any resources that already exist in AWS but are missing from state.
# Safe to run repeatedly — skips resources already in state.
# ============================================================================

# NOTE: do NOT use set -e here — we want the script to continue on failures
set -uo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-cicd-demo}"
CLUSTER="${PROJECT}-cluster"

IMPORT_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

tf_import() {
  local address="$1"
  local id="$2"

  # Check if already in state (suppress all output)
  if terraform state show "$address" > /dev/null 2>&1; then
    echo "  ⏭️  Already in state: $address"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    return 0
  fi

  echo "  📥 Importing: $address"
  # Run import, capture output for debugging
  local out
  if out=$(terraform import "$address" "$id" 2>&1); then
    echo "  ✅ Imported: $address"
    IMPORT_COUNT=$((IMPORT_COUNT + 1))
  else
    # Check if it failed because resource doesn't exist vs other error
    if echo "$out" | grep -qiE "NoSuch|NotFound|does not exist|Cannot import|404"; then
      echo "  ➕ Not found in AWS — will be created: $address"
    else
      echo "  ⚠️  Import failed for $address: $out"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  fi
}

echo "── Importing existing AWS resources into Terraform state ──"

# ── ECR ──────────────────────────────────────────────────────────────────────
echo "--- ECR ---"
if aws ecr describe-repositories --repository-names "$PROJECT" > /dev/null 2>&1; then
  tf_import "module.ecr.aws_ecr_repository.main" "$PROJECT"
  if aws ecr get-lifecycle-policy --repository-name "$PROJECT" > /dev/null 2>&1; then
    tf_import "module.ecr.aws_ecr_lifecycle_policy.main" "$PROJECT"
  fi
fi

# ── IAM ──────────────────────────────────────────────────────────────────────
echo "--- IAM ---"

if aws iam get-role --role-name "${PROJECT}-ecs-task-execution" > /dev/null 2>&1; then
  tf_import "module.ecs.aws_iam_role.task_execution" "${PROJECT}-ecs-task-execution"
  tf_import "module.ecs.aws_iam_role_policy_attachment.task_execution" \
    "${PROJECT}-ecs-task-execution/arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
fi

if aws iam get-role --role-name "${PROJECT}-ecs-instance" > /dev/null 2>&1; then
  tf_import "module.ecs.aws_iam_role.ecs_instance" "${PROJECT}-ecs-instance"
  tf_import "module.ecs.aws_iam_role_policy_attachment.ecs_instance" \
    "${PROJECT}-ecs-instance/arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
fi

if aws iam get-instance-profile --instance-profile-name "${PROJECT}-ecs-instance-profile" > /dev/null 2>&1; then
  tf_import "module.ecs.aws_iam_instance_profile.ecs_instance" "${PROJECT}-ecs-instance-profile"
fi

if aws iam get-role --role-name "${PROJECT}-github-actions" > /dev/null 2>&1; then
  tf_import "module.iam.aws_iam_role.github_actions" "${PROJECT}-github-actions"
fi

if aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" \
  > /dev/null 2>&1; then
  tf_import "module.iam.aws_iam_openid_connect_provider.github" \
    "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
fi

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT}-github-actions-policy"
if aws iam get-policy --policy-arn "$POLICY_ARN" > /dev/null 2>&1; then
  tf_import "module.iam.aws_iam_policy.github_actions" "$POLICY_ARN"
  tf_import "module.iam.aws_iam_role_policy_attachment.github_actions" \
    "${PROJECT}-github-actions/${POLICY_ARN}"
fi

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
echo "--- CloudWatch ---"
for ENV in dev staging prod; do
  LOG_EXISTS=$(aws logs describe-log-groups \
    --log-group-name-prefix "/ecs/${PROJECT}/${ENV}" \
    --query 'length(logGroups)' --output text 2>/dev/null || echo "0")
  if [[ "$LOG_EXISTS" != "0" && "$LOG_EXISTS" != "None" ]]; then
    tf_import "module.ecs.aws_cloudwatch_log_group.ecs[\"${ENV}\"]" "/ecs/${PROJECT}/${ENV}"
  fi
done

# ── VPC + Networking ──────────────────────────────────────────────────────────
echo "--- VPC ---"
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  tf_import "module.networking.aws_vpc.main" "$VPC_ID"

  IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
  [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]] && \
    tf_import "module.networking.aws_internet_gateway.main" "$IGW_ID"

  i=0
  while IFS= read -r SUBNET; do
    [[ -z "$SUBNET" || "$SUBNET" == "None" ]] && continue
    tf_import "module.networking.aws_subnet.public[${i}]" "$SUBNET"
    i=$((i+1))
  done < <(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT}-public-*" \
    --query 'Subnets[*].SubnetId' --output text 2>/dev/null | tr '\t' '\n')

  i=0
  while IFS= read -r SUBNET; do
    [[ -z "$SUBNET" || "$SUBNET" == "None" ]] && continue
    tf_import "module.networking.aws_subnet.private[${i}]" "$SUBNET"
    i=$((i+1))
  done < <(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT}-private-*" \
    --query 'Subnets[*].SubnetId' --output text 2>/dev/null | tr '\t' '\n')

  PUB_RT=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT}-public-rt" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "")
  [[ -n "$PUB_RT" && "$PUB_RT" != "None" ]] && \
    tf_import "module.networking.aws_route_table.public" "$PUB_RT"

  PRIV_RT=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT}-private-rt" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "")
  [[ -n "$PRIV_RT" && "$PRIV_RT" != "None" ]] && \
    tf_import "module.networking.aws_route_table.private" "$PRIV_RT"

  NAT_ID=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
    --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null || echo "")
  [[ -n "$NAT_ID" && "$NAT_ID" != "None" ]] && \
    tf_import "module.networking.aws_nat_gateway.main[0]" "$NAT_ID"

  EIP_ALLOC=$(aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=${PROJECT}-nat-eip*" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "")
  [[ -n "$EIP_ALLOC" && "$EIP_ALLOC" != "None" ]] && \
    tf_import "module.networking.aws_eip.nat[0]" "$EIP_ALLOC"

  if [[ -n "$PUB_RT" && "$PUB_RT" != "None" ]]; then
    i=0
    while IFS= read -r ASSOC; do
      [[ -z "$ASSOC" || "$ASSOC" == "None" ]] && continue
      tf_import "module.networking.aws_route_table_association.public[${i}]" "$ASSOC"
      i=$((i+1))
    done < <(aws ec2 describe-route-tables \
      --route-table-ids "$PUB_RT" \
      --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
      --output text 2>/dev/null | tr '\t' '\n')
  fi

  if [[ -n "$PRIV_RT" && "$PRIV_RT" != "None" ]]; then
    i=0
    while IFS= read -r ASSOC; do
      [[ -z "$ASSOC" || "$ASSOC" == "None" ]] && continue
      tf_import "module.networking.aws_route_table_association.private[${i}]" "$ASSOC"
      i=$((i+1))
    done < <(aws ec2 describe-route-tables \
      --route-table-ids "$PRIV_RT" \
      --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
      --output text 2>/dev/null | tr '\t' '\n')
  fi
fi

# ── Security Groups ───────────────────────────────────────────────────────────
echo "--- Security Groups ---"
ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT}-alb-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
[[ -n "$ALB_SG" && "$ALB_SG" != "None" ]] && \
  tf_import "module.ecs.aws_security_group.alb" "$ALB_SG"

ECS_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT}-ecs-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
[[ -n "$ECS_SG" && "$ECS_SG" != "None" ]] && \
  tf_import "module.ecs.aws_security_group.ecs_instances" "$ECS_SG"

# ── ALB ───────────────────────────────────────────────────────────────────────
echo "--- ALB ---"
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || echo "")

if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
  tf_import "module.ecs.aws_lb.main" "$ALB_ARN"

  for ENV in dev staging prod; do
    TG_ARN=$(aws elbv2 describe-target-groups \
      --names "${PROJECT}-${ENV}-tg" \
      --query 'TargetGroups[0].TargetGroupArn' \
      --output text 2>/dev/null || echo "")
    [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]] && \
      tf_import "module.ecs.aws_lb_target_group.env[\"${ENV}\"]" "$TG_ARN"
  done

  LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[?Port==`80`].ListenerArn' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$LISTENER_ARN" && "$LISTENER_ARN" != "None" ]]; then
    tf_import "module.ecs.aws_lb_listener.http" "$LISTENER_ARN"

    DEV_RULE=$(aws elbv2 describe-rules \
      --listener-arn "$LISTENER_ARN" \
      --query 'Rules[?Priority==`100`].RuleArn' \
      --output text 2>/dev/null || echo "")
    [[ -n "$DEV_RULE" && "$DEV_RULE" != "None" ]] && \
      tf_import "module.ecs.aws_lb_listener_rule.dev" "$DEV_RULE"

    STAGING_RULE=$(aws elbv2 describe-rules \
      --listener-arn "$LISTENER_ARN" \
      --query 'Rules[?Priority==`200`].RuleArn' \
      --output text 2>/dev/null || echo "")
    [[ -n "$STAGING_RULE" && "$STAGING_RULE" != "None" ]] && \
      tf_import "module.ecs.aws_lb_listener_rule.staging" "$STAGING_RULE"
  fi
fi

# ── ECS Cluster ───────────────────────────────────────────────────────────────
echo "--- ECS Cluster ---"
CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER" \
  --query 'clusters[0].status' --output text 2>/dev/null || echo "")
if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
  tf_import "module.ecs.aws_ecs_cluster.main" \
    "arn:aws:ecs:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER}"
  tf_import "module.ecs.aws_ecs_cluster_capacity_providers.main" "$CLUSTER"
fi

CP_ARN=$(aws ecs describe-capacity-providers \
  --capacity-providers "${PROJECT}-cp" \
  --query 'capacityProviders[0].capacityProviderArn' \
  --output text 2>/dev/null || echo "")
[[ -n "$CP_ARN" && "$CP_ARN" != "None" ]] && \
  tf_import "module.ecs.aws_ecs_capacity_provider.main" "${PROJECT}-cp"

# ── ASG + Launch Template ─────────────────────────────────────────────────────
echo "--- ASG ---"
ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${PROJECT}-ecs-asg" \
  --query 'AutoScalingGroups[0].AutoScalingGroupName' \
  --output text 2>/dev/null || echo "")
[[ -n "$ASG" && "$ASG" != "None" ]] && \
  tf_import "module.ecs.aws_autoscaling_group.ecs" "$ASG"

LT_ID=$(aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=${PROJECT}-ecs-*" \
  --query 'LaunchTemplates[0].LaunchTemplateId' \
  --output text 2>/dev/null || echo "")
[[ -n "$LT_ID" && "$LT_ID" != "None" ]] && \
  tf_import "module.ecs.aws_launch_template.ecs" "$LT_ID"

# ── ECS Services + Task Definitions ──────────────────────────────────────────
echo "--- ECS Services ---"
for ENV in dev staging prod; do
  SVC=$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "${PROJECT}-${ENV}" \
    --query 'services[?status==`ACTIVE`].serviceName' \
    --output text 2>/dev/null || echo "")
  [[ -n "$SVC" && "$SVC" != "None" ]] && \
    tf_import "module.ecs.aws_ecs_service.${ENV}" "${CLUSTER}/${PROJECT}-${ENV}"

  TD=$(aws ecs describe-task-definition \
    --task-definition "${PROJECT}-${ENV}" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text 2>/dev/null || echo "")
  [[ -n "$TD" && "$TD" != "None" ]] && \
    tf_import "module.ecs.aws_ecs_task_definition.env[\"${ENV}\"]" "$TD"
done

echo ""
echo "── Import complete: ${IMPORT_COUNT} imported, ${SKIP_COUNT} skipped, ${FAIL_COUNT} failed ──"