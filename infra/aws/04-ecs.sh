#!/usr/bin/env bash
# Execution role, task definition, ECS cluster, ALB + target group, ECS service on Fargate.
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")"
: "${FIRST_IMAGE:?run 03-image.sh first}" "${DB_HOST:?run 02-database.sh first}"

step "IAM execution role $EXEC_ROLE (lets ECS pull the image, read SSM, write logs)"
if ! aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$EXEC_ROLE" --query Role.Arn --output text \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
fi
aws iam attach-role-policy --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name read-spry-ssm --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"ssm:GetParameters\",\"Resource\":\"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter/spry/*\"}]}"
EXEC_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$EXEC_ROLE"

step "Log group /ecs/$ECS_SERVICE (7 days)"
aws logs create-log-group --log-group-name "/ecs/$ECS_SERVICE" 2>/dev/null || echo "   (already there)"
aws logs put-retention-policy --log-group-name "/ecs/$ECS_SERVICE" --retention-in-days 7

step "Task definition $ECS_TASK_FAMILY"
cat > taskdef.rendered.json <<JSON
{
  "family": "$ECS_TASK_FAMILY",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "256",
  "memory": "512",
  "runtimePlatform": { "cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX" },
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "containerDefinitions": [{
    "name": "$CONTAINER_NAME",
    "image": "$FIRST_IMAGE",
    "essential": true,
    "portMappings": [{ "containerPort": 8000, "protocol": "tcp" }],
    "environment": [{ "name": "CORS_ORIGINS", "value": "${CORS_ORIGINS:-http://localhost:5173}" }],
    "secrets": [{ "name": "DATABASE_URL",
                  "valueFrom": "arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter/spry/DATABASE_URL" }],
    "logConfiguration": { "logDriver": "awslogs", "options": {
      "awslogs-group": "/ecs/$ECS_SERVICE", "awslogs-region": "$AWS_REGION",
      "awslogs-stream-prefix": "backend" } }
  }]
}
JSON
# IAM is eventually consistent: a brand-new role can take a few seconds to be usable.
sleep 10
TASKDEF_ARN=$(t aws ecs register-task-definition --cli-input-json file://taskdef.rendered.json \
  --query taskDefinition.taskDefinitionArn --output text)
rm -f taskdef.rendered.json
echo "$TASKDEF_ARN"

step "ECS cluster $ECS_CLUSTER"
aws ecs create-cluster --cluster-name "$ECS_CLUSTER" --query cluster.status --output text

step "Target group (health check: GET /api/health → 200)"
TG_ARN=$(aws elbv2 describe-target-groups --names spry-backend \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | tr -d '\r' || true)
if [[ -z "$TG_ARN" ]]; then
  TG_ARN=$(t aws elbv2 create-target-group --name spry-backend --protocol HTTP --port 8000 \
    --vpc-id "$VPC_ID" --target-type ip --health-check-path /api/health --matcher HttpCode=200 \
    --health-check-interval-seconds 15 --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
# Default draining is 300 s, which makes every deploy 5 min slower.
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
save TG_ARN "$TG_ARN"

step "Application Load Balancer spry-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --names spry-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | tr -d '\r' || true)
if [[ -z "$ALB_ARN" ]]; then
  ALB_ARN=$(t aws elbv2 create-load-balancer --name spry-alb --type application \
    --scheme internet-facing --subnets ${SUBNETS_CSV//,/ } --security-groups "$SG_ALB" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi
ALB_DNS=$(t aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
save ALB_ARN "$ALB_ARN"; save ALB_DNS "$ALB_DNS"

HTTP_LISTENER=$(t aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text)
if [[ "$HTTP_LISTENER" == "None" ]]; then
  HTTP_LISTENER=$(t aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" --query 'Listeners[0].ListenerArn' --output text)
fi
save HTTP_LISTENER "$HTTP_LISTENER"

step "ECS service $ECS_SERVICE on Fargate"
SERVICE_STATUS=$(t aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].status' --output text)
if [[ "$SERVICE_STATUS" != "ACTIVE" ]]; then
  aws ecs create-service --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
    --task-definition "$TASKDEF_ARN" --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_CSV],securityGroups=[$SG_ECS],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER_NAME,containerPort=8000" \
    --health-check-grace-period-seconds 60 \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},minimumHealthyPercent=100,maximumPercent=200" \
    --query service.serviceName --output text
else
  echo "   (service already exists — deploys go through 'make deploy-backend')"
fi

step "Waiting for the service to become stable (3–6 min)…"
aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"

step "Smoke test"
curl -fsS "http://$ALB_DNS/api/health" && echo
curl -fsS "http://$ALB_DNS/api/meetings" && echo
echo "Backend is up at http://$ALB_DNS/api/docs"
echo "Done. Next: bash infra/aws/05-frontend.sh"
