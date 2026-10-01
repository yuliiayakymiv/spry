#!/usr/bin/env bash
# Default VPC + three security groups: internet → ALB → ECS tasks → RDS.
source "$(dirname "$0")/env.sh"

step "Default VPC and its subnets"
VPC_ID=$(t aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
if [[ "$VPC_ID" == "None" ]]; then
  echo "No default VPC in $AWS_REGION — creating one"
  VPC_ID=$(t aws ec2 create-default-vpc --query Vpc.VpcId --output text)
fi
SUBNETS=$(t aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=default-for-az,Values=true" \
  --query 'Subnets[].SubnetId' --output text)
SUBNETS_CSV=$(echo $SUBNETS | tr ' ' ',')
echo "VPC $VPC_ID, subnets $SUBNETS_CSV"
save VPC_ID "$VPC_ID"
save SUBNETS_CSV "$SUBNETS_CSV"

# Find a security group by name, or create it.
sg() {
  local id
  id=$(t aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$1" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [[ "$id" == "None" ]]; then
    id=$(t aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC_ID" \
      --query GroupId --output text)
  fi
  echo "$id"
}
# Add an ingress rule; "already exists" is fine on a re-run.
allow() { aws ec2 authorize-security-group-ingress "$@" >/dev/null 2>&1 || echo "   (rule already there)"; }

step "Security groups"
SG_ALB=$(sg spry-alb "Spry ALB: HTTP/HTTPS from the internet")
SG_ECS=$(sg spry-ecs "Spry tasks: port 8000 from the ALB only")
SG_RDS=$(sg spry-rds "Spry RDS: port 5432 from the tasks only")
allow --group-id "$SG_ALB" --protocol tcp --port 80   --cidr 0.0.0.0/0
allow --group-id "$SG_ALB" --protocol tcp --port 443  --cidr 0.0.0.0/0
allow --group-id "$SG_ECS" --protocol tcp --port 8000 --source-group "$SG_ALB"
allow --group-id "$SG_RDS" --protocol tcp --port 5432 --source-group "$SG_ECS"
save SG_ALB "$SG_ALB"; save SG_ECS "$SG_ECS"; save SG_RDS "$SG_RDS"
echo "ALB $SG_ALB · ECS $SG_ECS · RDS $SG_RDS"
echo "Done. Next: bash infra/aws/02-database.sh"
