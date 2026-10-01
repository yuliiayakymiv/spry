#!/usr/bin/env bash
# Delete everything the 01-06 scripts created, so nothing keeps billing.
# Run AFTER the lab is graded. The order matters (dependencies first).
source "$(dirname "$0")/env.sh"
read -r -p "Delete ALL Spry resources in $AWS_REGION (account $ACCOUNT_ID)? Type 'delete': " ok
[[ "$ok" == "delete" ]] || { echo "Cancelled."; exit 1; }
try() { "$@" >/dev/null 2>&1 && echo "   ok: $*" || echo "   skip: $*"; }

step "ECS service and cluster"
try aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --desired-count 0
try aws ecs delete-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" --force
step "Load balancer and target group"
[[ -n "${ALB_ARN:-}" ]] && try aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
sleep 20
[[ -n "${TG_ARN:-}" ]] && try aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
try aws ecs delete-cluster --cluster "$ECS_CLUSTER"
step "Database (no final snapshot)"
try aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE" --skip-final-snapshot --delete-automated-backups
step "ECR repository and S3 bucket"
try aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --force
[[ -n "${S3_BUCKET:-}" ]] && try aws s3 rb "s3://$S3_BUCKET" --force
step "SSM parameters, log group"
try aws ssm delete-parameters --names /spry/DATABASE_URL /spry/DB_PASSWORD
try aws logs delete-log-group --log-group-name "/ecs/$ECS_SERVICE"
step "IAM roles"
try aws iam delete-role-policy --role-name "$DEPLOY_ROLE" --policy-name deploy-spry
try aws iam delete-role --role-name "$DEPLOY_ROLE"
try aws iam delete-role-policy --role-name "$EXEC_ROLE" --policy-name read-spry-ssm
try aws iam detach-role-policy --role-name "$EXEC_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
try aws iam delete-role --role-name "$EXEC_ROLE"
cat <<TXT

Left for you to do by hand (they can't be deleted instantly):
 - CloudFront ${CF_DIST_ID:-}: console → CloudFront → Disable → wait ~10 min → Delete
 - Security groups spry-alb / spry-ecs / spry-rds: EC2 → Security Groups → delete
   (after the database has finished deleting, ~10 min)
 - ACM certificates, if you created any
TXT
