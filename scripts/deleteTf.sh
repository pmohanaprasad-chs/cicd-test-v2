ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"
PROJECT="cicd-demo"
CLUSTER="${PROJECT}-cluster"

echo "============================================"
echo "  Deleting all $PROJECT resources"
echo "============================================"

# ── ECS Services (scale down first, then delete) ──────────────────────────────
echo ""
echo "── ECS Services ─────────────────────────────────"
for ENV in dev staging prod; do
  echo "Deleting ECS service: ${PROJECT}-${ENV}"
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "${PROJECT}-${ENV}" \
    --desired-count 0 2>/dev/null || true
  aws ecs delete-service \
    --cluster "$CLUSTER" \
    --service "${PROJECT}-${ENV}" \
    --force 2>/dev/null && echo "✅ Deleted ${PROJECT}-${ENV}" || echo "⏭️  Not found"
done

# ── ECS Capacity Provider (must detach before delete) ─────────────────────────
echo ""
echo "── ECS Capacity Provider ────────────────────────"
aws ecs put-cluster-capacity-providers \
  --cluster "$CLUSTER" \
  --capacity-providers [] \
  --default-capacity-provider-strategy [] 2>/dev/null || true

aws ecs delete-capacity-provider \
  --capacity-provider "${PROJECT}-cp" 2>/dev/null && \
  echo "✅ Deleted capacity provider" || echo "⏭️  Not found"

# ── ECS Cluster ───────────────────────────────────────────────────────────────
echo ""
echo "── ECS Cluster ──────────────────────────────────"
aws ecs delete-cluster \
  --cluster "$CLUSTER" 2>/dev/null && \
  echo "✅ Deleted cluster" || echo "⏭️  Not found"

# ── Auto Scaling Group ────────────────────────────────────────────────────────
echo ""
echo "── Auto Scaling Group ───────────────────────────"
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "${PROJECT}-ecs-asg" \
  --force-delete 2>/dev/null && \
  echo "✅ Deleted ASG" || echo "⏭️  Not found"

# Wait for ASG to finish deleting
echo "Waiting for ASG deletion..."
sleep 30

# ── Launch Template ───────────────────────────────────────────────────────────
echo ""
echo "── Launch Template ──────────────────────────────"
LT_ID=$(aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=${PROJECT}-ecs-*" \
  --query 'LaunchTemplates[0].LaunchTemplateId' \
  --output text 2>/dev/null || echo "")
if [[ -n "$LT_ID" && "$LT_ID" != "None" ]]; then
  aws ec2 delete-launch-template --launch-template-id "$LT_ID" && \
    echo "✅ Deleted launch template" || echo "⏭️  Not found"
fi

# ── ALB + Listeners + Rules + Target Groups ───────────────────────────────────
echo ""
echo "── ALB ──────────────────────────────────────────"
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || echo "")

if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
  # Delete listeners first
  LISTENERS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[*].ListenerArn' \
    --output text 2>/dev/null || echo "")
  for L in $LISTENERS; do
    aws elbv2 delete-listener --listener-arn "$L" 2>/dev/null || true
  done

  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  echo "✅ Deleted ALB — waiting for deletion..."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
fi

# Delete Target Groups
echo ""
echo "── Target Groups ────────────────────────────────"
for ENV in dev staging prod; do
  TG_ARN=$(aws elbv2 describe-target-groups \
    --names "${PROJECT}-${ENV}-tg" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || echo "")
  if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" && \
      echo "✅ Deleted ${PROJECT}-${ENV}-tg" || echo "⏭️  Not found"
  fi
done

# ── ECR Repository ────────────────────────────────────────────────────────────
echo ""
echo "── ECR ──────────────────────────────────────────"
aws ecr delete-repository \
  --repository-name "$PROJECT" \
  --force 2>/dev/null && \
  echo "✅ Deleted ECR repo" || echo "⏭️  Not found"

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
echo ""
echo "── CloudWatch Log Groups ────────────────────────"
for ENV in dev staging prod; do
  aws logs delete-log-group \
    --log-group-name "/ecs/${PROJECT}/${ENV}" 2>/dev/null && \
    echo "✅ Deleted log group /ecs/${PROJECT}/${ENV}" || echo "⏭️  Not found"
done

# ── Security Groups ───────────────────────────────────────────────────────────
echo ""
echo "── Security Groups ──────────────────────────────"
for SG_NAME in "${PROJECT}-alb-sg" "${PROJECT}-ecs-sg"; do
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
  if [[ -n "$SG_ID" && "$SG_ID" != "None" ]]; then
    aws ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null && \
      echo "✅ Deleted $SG_NAME" || echo "⚠️  Could not delete $SG_NAME (may still have dependencies)"
  fi
done

# ── NAT Gateway + EIP ─────────────────────────────────────────────────────────
echo ""
echo "── NAT Gateway ──────────────────────────────────"
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")

if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
  NAT_IDS=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
    --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null || echo "")

  for NAT_ID in $NAT_IDS; do
    aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID"
    echo "✅ Deleting NAT Gateway $NAT_ID — waiting..."
  done

  if [[ -n "$NAT_IDS" ]]; then
    aws ec2 wait nat-gateway-deleted \
      --filter "Name=nat-gateway-id,Values=$(echo $NAT_IDS | tr ' ' ',')" 2>/dev/null || \
      sleep 60
  fi

  # Release EIPs
  EIP_ALLOCS=$(aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=${PROJECT}-nat-eip*" \
    --query 'Addresses[*].AllocationId' --output text 2>/dev/null || echo "")
  for ALLOC in $EIP_ALLOCS; do
    aws ec2 release-address --allocation-id "$ALLOC" && \
      echo "✅ Released EIP $ALLOC" || true
  done

  # ── VPC Resources ────────────────────────────────────────────────────────────
  echo ""
  echo "── VPC Resources ────────────────────────────────"

  # Route table associations + route tables
  RT_IDS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
    --output text 2>/dev/null || echo "")

  for RT_ID in $RT_IDS; do
    # Delete associations first
    ASSOC_IDS=$(aws ec2 describe-route-tables \
      --route-table-ids "$RT_ID" \
      --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
      --output text 2>/dev/null || echo "")
    for ASSOC in $ASSOC_IDS; do
      aws ec2 disassociate-route-table --association-id "$ASSOC" 2>/dev/null || true
    done
    aws ec2 delete-route-table --route-table-id "$RT_ID" 2>/dev/null && \
      echo "✅ Deleted route table $RT_ID" || true
  done

  # Subnets
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[*].SubnetId' --output text 2>/dev/null || echo "")
  for SUBNET_ID in $SUBNET_IDS; do
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID" 2>/dev/null && \
      echo "✅ Deleted subnet $SUBNET_ID" || true
  done

  # Internet Gateway
  IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
  if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" && \
      echo "✅ Deleted internet gateway"
  fi

  # VPC
  aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null && \
    echo "✅ Deleted VPC $VPC_ID" || echo "⚠️  Could not delete VPC (check for remaining dependencies)"
fi

# ── IAM ───────────────────────────────────────────────────────────────────────
echo ""
echo "── IAM ──────────────────────────────────────────"
for ROLE in "${PROJECT}-ecs-task-execution" "${PROJECT}-ecs-instance" "${PROJECT}-github-actions"; do
  # Detach all policies first
  POLICIES=$(aws iam list-attached-role-policies \
    --role-name "$ROLE" \
    --query 'AttachedPolicies[*].PolicyArn' \
    --output text 2>/dev/null || echo "")
  for P in $POLICIES; do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$P" 2>/dev/null || true
  done
  # Remove from instance profile if applicable
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "${PROJECT}-ecs-instance-profile" \
    --role-name "$ROLE" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && \
    echo "✅ Deleted role $ROLE" || echo "⏭️  Not found"
done

aws iam delete-instance-profile \
  --instance-profile-name "${PROJECT}-ecs-instance-profile" 2>/dev/null && \
  echo "✅ Deleted instance profile" || echo "⏭️  Not found"

# Delete custom policy
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${PROJECT}-github-actions-policy"
aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null && \
  echo "✅ Deleted custom policy" || echo "⏭️  Not found"

# ── ECS Task Definitions (deregister all revisions) ───────────────────────────
echo ""
echo "── ECS Task Definitions ─────────────────────────"
for ENV in dev staging prod; do
  TASK_DEFS=$(aws ecs list-task-definitions \
    --family-prefix "${PROJECT}-${ENV}" \
    --query 'taskDefinitionArns[*]' \
    --output text 2>/dev/null || echo "")
  for TD in $TASK_DEFS; do
    aws ecs deregister-task-definition --task-definition "$TD" > /dev/null 2>&1 && \
      echo "✅ Deregistered $TD" || true
  done
done

echo ""
echo "============================================"
echo "  ✅ Cleanup complete"
echo "  Note: OIDC provider kept (shared resource)"
echo "  Note: S3 state bucket kept"
echo "  Note: DynamoDB lock table kept"
echo "============================================"