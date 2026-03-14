#!/usr/bin/env bash
# scripts/tf-import-ci.sh
# ============================================================================
# Import existing AWS resources into Terraform state before plan/apply.
# Runs inside the _provision.yml reusable workflow.
#
# Required env vars (set by the workflow):
#   AWS_REGION    — e.g. us-east-1
#   PROJECT_NAME  — e.g. my-app
#   ENVIRONMENT   — dev | staging | prod
#
# Design rules:
#   - NO set -e — script must continue on individual import failures
#   - Every resource is guarded with an AWS existence check before importing
#   - terraform state show before each import to skip already-managed resources
# ============================================================================

set -uo pipefail

P="${PROJECT_NAME}"
ENV="${ENVIRONMENT}"
REGION="${AWS_REGION}"

echo "=== tf-import-ci.sh | project=${P} env=${ENV} region=${REGION} ==="

# Helper: import only if not already in state
import_if_missing() {
  local address="$1"
  local id="$2"
  if terraform state show "$address" > /dev/null 2>&1; then
    echo "  ⏭️  Already in state: ${address}"
  else
    echo "  → Importing: ${address} = ${id}"
    terraform import "$address" "$id" || echo "  ⚠️  Import failed (may not exist): ${address}"
  fi
}

# ── OIDC Provider ─────────────────────────────────────────────────────────────
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn,'token.actions.githubusercontent.com')].Arn" \
  --output text 2>/dev/null || echo "")
if [[ -n "$OIDC_ARN" && "$OIDC_ARN" != "None" ]]; then
  import_if_missing "module.iam.aws_iam_openid_connect_provider.github" "$OIDC_ARN"
fi

# ── GitHub Actions IAM Role ───────────────────────────────────────────────────
ROLE_ARN=$(aws iam get-role --role-name "${P}-github-actions" \
  --query "Role.Arn" --output text 2>/dev/null || echo "")
if [[ -n "$ROLE_ARN" && "$ROLE_ARN" != "None" ]]; then
  import_if_missing "module.iam.aws_iam_role.github_actions" "${P}-github-actions"
fi

POLICY_ARN=$(aws iam list-policies \
  --query "Policies[?PolicyName=='${P}-github-actions-policy'].Arn" \
  --output text 2>/dev/null || echo "")
if [[ -n "$POLICY_ARN" && "$POLICY_ARN" != "None" ]]; then
  import_if_missing "module.iam.aws_iam_policy.github_actions" "$POLICY_ARN"
  import_if_missing \
    "module.iam.aws_iam_role_policy_attachment.github_actions" \
    "${P}-github-actions/${POLICY_ARN}"
fi

# ── ECR (prod account only) ────────────────────────────────────────────────────
if [[ "$ENV" == "prod" ]]; then
  ECR_EXISTS=$(aws ecr describe-repositories --repository-names "$P" \
    --query "repositories[0].repositoryName" --output text 2>/dev/null || echo "")
  if [[ -n "$ECR_EXISTS" && "$ECR_EXISTS" != "None" ]]; then
    import_if_missing "module.ecr.aws_ecr_repository.main" "$P"
  fi
fi

# ── VPC (all accounts have VPC + ECS) ─────────────────────────────────────────
if [[ true ]]; then
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${P}-vpc" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "")
  if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    import_if_missing "module.networking.aws_vpc.main" "$VPC_ID"

    # Internet Gateway
    IGW_ID=$(aws ec2 describe-internet-gateways \
      --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
      --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || echo "")
    if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
      import_if_missing "module.networking.aws_internet_gateway.main" "$IGW_ID"
    fi

    # Public subnets
    PUBLIC_SUBNET_IDS=()
    while IFS= read -r subnet_id; do
      [[ -z "$subnet_id" || "$subnet_id" == "None" ]] && continue
      PUBLIC_SUBNET_IDS+=("$subnet_id")
    done < <(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${P}-public-*" \
      --query "Subnets[*].SubnetId" --output text 2>/dev/null | tr '\t' '\n')

    for i in "${!PUBLIC_SUBNET_IDS[@]}"; do
      import_if_missing \
        "module.networking.aws_subnet.public[${i}]" \
        "${PUBLIC_SUBNET_IDS[$i]}"
    done

    # Private subnets
    PRIVATE_SUBNET_IDS=()
    while IFS= read -r subnet_id; do
      [[ -z "$subnet_id" || "$subnet_id" == "None" ]] && continue
      PRIVATE_SUBNET_IDS+=("$subnet_id")
    done < <(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${P}-private-*" \
      --query "Subnets[*].SubnetId" --output text 2>/dev/null | tr '\t' '\n')

    for i in "${!PRIVATE_SUBNET_IDS[@]}"; do
      import_if_missing \
        "module.networking.aws_subnet.private[${i}]" \
        "${PRIVATE_SUBNET_IDS[$i]}"
    done

    # NAT Gateway + EIP
    NAT_ID=$(aws ec2 describe-nat-gateways \
      --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
      --query "NatGateways[0].NatGatewayId" --output text 2>/dev/null || echo "")
    if [[ -n "$NAT_ID" && "$NAT_ID" != "None" ]]; then
      import_if_missing "module.networking.aws_nat_gateway.main[0]" "$NAT_ID"
      EIP_ALLOC=$(aws ec2 describe-nat-gateways \
        --nat-gateway-ids "$NAT_ID" \
        --query "NatGateways[0].NatGatewayAddresses[0].AllocationId" \
        --output text 2>/dev/null || echo "")
      if [[ -n "$EIP_ALLOC" && "$EIP_ALLOC" != "None" ]]; then
        import_if_missing "module.networking.aws_eip.nat[0]" "$EIP_ALLOC"
      fi
    fi

    # Route tables
    PUBLIC_RT=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${P}-public-rt" \
      --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || echo "")
    if [[ -n "$PUBLIC_RT" && "$PUBLIC_RT" != "None" ]]; then
      import_if_missing "module.networking.aws_route_table.public" "$PUBLIC_RT"
      # Route table associations
      ASSOC_IDS=()
      while IFS= read -r assoc_id; do
        [[ -z "$assoc_id" || "$assoc_id" == "None" ]] && continue
        ASSOC_IDS+=("$assoc_id")
      done < <(aws ec2 describe-route-tables \
        --route-table-ids "$PUBLIC_RT" \
        --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" \
        --output text 2>/dev/null | tr '\t' '\n')

      for i in "${!ASSOC_IDS[@]}"; do
        import_if_missing \
          "module.networking.aws_route_table_association.public[${i}]" \
          "${ASSOC_IDS[$i]}"
      done
    fi

    PRIVATE_RT=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${P}-private-rt" \
      --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || echo "")
    if [[ -n "$PRIVATE_RT" && "$PRIVATE_RT" != "None" ]]; then
      import_if_missing "module.networking.aws_route_table.private" "$PRIVATE_RT"
      PRIVATE_ASSOC_IDS=()
      while IFS= read -r assoc_id; do
        [[ -z "$assoc_id" || "$assoc_id" == "None" ]] && continue
        PRIVATE_ASSOC_IDS+=("$assoc_id")
      done < <(aws ec2 describe-route-tables \
        --route-table-ids "$PRIVATE_RT" \
        --query "RouteTables[0].Associations[?!Main].RouteTableAssociationId" \
        --output text 2>/dev/null | tr '\t' '\n')

      for i in "${!PRIVATE_ASSOC_IDS[@]}"; do
        import_if_missing \
          "module.networking.aws_route_table_association.private[${i}]" \
          "${PRIVATE_ASSOC_IDS[$i]}"
      done
    fi

    # Security Groups
    ALB_SG=$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${P}-alb-sg" \
      --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")
    if [[ -n "$ALB_SG" && "$ALB_SG" != "None" ]]; then
      import_if_missing "module.ecs.aws_security_group.alb" "$ALB_SG"
    fi

    ECS_SG=$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${P}-ecs-sg" \
      --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")
    if [[ -n "$ECS_SG" && "$ECS_SG" != "None" ]]; then
      import_if_missing "module.ecs.aws_security_group.ecs_instances" "$ECS_SG"
    fi

    # ALB
    ALB_ARN=$(aws elbv2 describe-load-balancers \
      --names "${P}-alb" \
      --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || echo "")
    if [[ -n "$ALB_ARN" && "$ALB_ARN" != "None" ]]; then
      import_if_missing "module.ecs.aws_lb.main" "$ALB_ARN"

      # Listener
      LISTENER_ARN=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$ALB_ARN" \
        --query "Listeners[?Port==\`80\`].ListenerArn" --output text 2>/dev/null || echo "")
      if [[ -n "$LISTENER_ARN" && "$LISTENER_ARN" != "None" ]]; then
        import_if_missing "module.ecs.aws_lb_listener.http" "$LISTENER_ARN"

        # Path-based rule (dev/staging only)
        if [[ "$ENV" != "prod" ]]; then
          RULE_ARN=$(aws elbv2 describe-rules \
            --listener-arn "$LISTENER_ARN" \
            --query "Rules[?Conditions[?Field=='path-pattern' && Values[0]=='/${ENV}']].RuleArn" \
            --output text 2>/dev/null || echo "")
          if [[ -n "$RULE_ARN" && "$RULE_ARN" != "None" ]]; then
            import_if_missing "module.ecs.aws_lb_listener_rule.env_path[0]" "$RULE_ARN"
          fi
        fi
      fi

      # Target Group
      TG_ARN=$(aws elbv2 describe-target-groups \
        --names "${P}-${ENV}-tg" \
        --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || echo "")
      if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
        import_if_missing "module.ecs.aws_lb_target_group.env" "$TG_ARN"
      fi
    fi

    # ECS Cluster
    CLUSTER_ARN=$(aws ecs describe-clusters \
      --clusters "${P}-cluster" \
      --query "clusters[?status=='ACTIVE'].clusterArn" --output text 2>/dev/null || echo "")
    if [[ -n "$CLUSTER_ARN" && "$CLUSTER_ARN" != "None" ]]; then
      import_if_missing "module.ecs.aws_ecs_cluster.main" "$CLUSTER_ARN"
    fi

    # Capacity Provider
    CP_EXISTS=$(aws ecs describe-capacity-providers \
      --capacity-providers "${P}-cp" \
      --query "capacityProviders[0].name" --output text 2>/dev/null || echo "")
    if [[ -n "$CP_EXISTS" && "$CP_EXISTS" != "None" ]]; then
      import_if_missing "module.ecs.aws_ecs_capacity_provider.main" "${P}-cp"
    fi

    # Cluster capacity providers association
    if [[ -n "$CLUSTER_ARN" && "$CLUSTER_ARN" != "None" ]]; then
      import_if_missing \
        "module.ecs.aws_ecs_cluster_capacity_providers.main" \
        "${P}-cluster"
    fi

    # ASG
    ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "${P}-ecs-asg" \
      --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || echo "")
    if [[ -n "$ASG_EXISTS" && "$ASG_EXISTS" != "None" ]]; then
      import_if_missing "module.ecs.aws_autoscaling_group.ecs" "${P}-ecs-asg"
    fi

    # Launch Template (latest version)
    LT_ID=$(aws ec2 describe-launch-templates \
      --filters "Name=launch-template-name,Values=${P}-ecs-*" \
      --query "LaunchTemplates[0].LaunchTemplateId" --output text 2>/dev/null || echo "")
    if [[ -n "$LT_ID" && "$LT_ID" != "None" ]]; then
      import_if_missing "module.ecs.aws_launch_template.ecs" "$LT_ID"
    fi

    # ECS Task Execution Role
    TE_ROLE=$(aws iam get-role --role-name "${P}-ecs-task-execution" \
      --query "Role.RoleName" --output text 2>/dev/null || echo "")
    if [[ -n "$TE_ROLE" && "$TE_ROLE" != "None" ]]; then
      import_if_missing "module.ecs.aws_iam_role.task_execution" "${P}-ecs-task-execution"
      import_if_missing \
        "module.ecs.aws_iam_role_policy_attachment.task_execution_base" \
        "${P}-ecs-task-execution/arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    fi

    # ECS Instance Role
    EC2_ROLE=$(aws iam get-role --role-name "${P}-ecs-instance" \
      --query "Role.RoleName" --output text 2>/dev/null || echo "")
    if [[ -n "$EC2_ROLE" && "$EC2_ROLE" != "None" ]]; then
      import_if_missing "module.ecs.aws_iam_role.ecs_instance" "${P}-ecs-instance"
      import_if_missing \
        "module.ecs.aws_iam_role_policy_attachment.ecs_instance" \
        "${P}-ecs-instance/arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
      PROFILE_EXISTS=$(aws iam get-instance-profile \
        --instance-profile-name "${P}-ecs-instance-profile" \
        --query "InstanceProfile.InstanceProfileName" --output text 2>/dev/null || echo "")
      if [[ -n "$PROFILE_EXISTS" && "$PROFILE_EXISTS" != "None" ]]; then
        import_if_missing \
          "module.ecs.aws_iam_instance_profile.ecs_instance" \
          "${P}-ecs-instance-profile"
      fi
    fi

    # CloudWatch Log Group
    LOG_GROUP=$(aws logs describe-log-groups \
      --log-group-name-prefix "/ecs/${P}/${ENV}" \
      --query "logGroups[0].logGroupName" --output text 2>/dev/null || echo "")
    if [[ -n "$LOG_GROUP" && "$LOG_GROUP" != "None" ]]; then
      import_if_missing "module.ecs.aws_cloudwatch_log_group.ecs" "$LOG_GROUP"
    fi

    # ECS Task Definition
    TD_ARN=$(aws ecs describe-task-definition \
      --task-definition "${P}-${ENV}" \
      --query "taskDefinition.taskDefinitionArn" --output text 2>/dev/null || echo "")
    if [[ -n "$TD_ARN" && "$TD_ARN" != "None" ]]; then
      import_if_missing "module.ecs.aws_ecs_task_definition.env" "$TD_ARN"
    fi

    # ECS Service
    SVC_ARN=$(aws ecs describe-services \
      --cluster "${P}-cluster" \
      --services "${P}-${ENV}" \
      --query "services[?status=='ACTIVE'].serviceArn" --output text 2>/dev/null || echo "")
    if [[ -n "$SVC_ARN" && "$SVC_ARN" != "None" ]]; then
      import_if_missing "module.ecs.aws_ecs_service.env" "${P}-cluster/${P}-${ENV}"
    fi
  fi
fi

echo "=== tf-import-ci.sh complete ==="
