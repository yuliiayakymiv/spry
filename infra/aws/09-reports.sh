#!/usr/bin/env bash
# Weekly report (Lab 5): deploys infra/reports.yml as the CloudFormation stack spry-reports.
# Run AFTER a backend image with app/reports and awslambdaric is deployed (push to main → CI,
# or `make deploy-backend`): the builder Lambda reuses the image the ECS service runs now.
# Needs in the repo-root .env (git-ignored):
#   REPORT_RECIPIENTS=you@example.com        comma-separated; verified identities in the SES sandbox
#   REPORT_SENDER_DOMAIN=                    optional; empty = send from the first recipient
# Optional: SCHEDULE='rate(5 minutes)' REPORT_FAIL_WEEK=2026-W39 make deploy-reports
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/../.."
: "${VPC_ID:?run 01-network.sh first}" "${SUBNETS_CSV:?run 01-network.sh first}" \
  "${SG_ECS:?run 01-network.sh first}"

envval() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"'; }
RECIPIENTS="${REPORT_RECIPIENTS:-$(envval REPORT_RECIPIENTS)}"
SENDER_DOMAIN="${REPORT_SENDER_DOMAIN:-$(envval REPORT_SENDER_DOMAIN)}"
: "${RECIPIENTS:?set REPORT_RECIPIENTS in .env}"
REPORTS_STACK="${REPORTS_STACK:-spry-reports}"

step "Inputs"
# The default VPC's subnets use its main route table; the S3 gateway endpoint goes there.
ROUTE_TABLE=$(t aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
  --query 'RouteTables[0].RouteTableId' --output text)
TASKDEF=$(t aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].taskDefinition' --output text)
IMAGE_URI=$(t aws ecs describe-task-definition --task-definition "$TASKDEF" \
  --query "taskDefinition.containerDefinitions[?name=='$CONTAINER_NAME'].image | [0]" --output text)
# The builder sits in a VPC without NAT, so it cannot read SSM at run time: the value goes into
# its (KMS-encrypted) environment instead. NoEcho keeps it out of the stack's parameter view.
DATABASE_URL=$(t aws ssm get-parameter --name /spry/DATABASE_URL --with-decryption \
  --query Parameter.Value --output text)
echo "   route table: $ROUTE_TABLE"
echo "   image:       $IMAGE_URI"
echo "   recipients:  $RECIPIENTS"

step "CloudFormation stack $REPORTS_STACK (bucket, S3 endpoint, queue + DLQ, schedule, 2 Lambdas, SES)"
aws cloudformation deploy --stack-name "$REPORTS_STACK" --template-file infra/reports.yml \
  --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --tags PROJECT_NAME=spry \
  --parameter-overrides ImageUri="$IMAGE_URI" DatabaseUrl="$DATABASE_URL" \
    VpcId="$VPC_ID" SubnetIds="$SUBNETS_CSV" RouteTableIds="$ROUTE_TABLE" SecurityGroupId="$SG_ECS" \
    RecipientEmails="$RECIPIENTS" SenderDomain="$SENDER_DOMAIN" \
    ScheduleExpression="${SCHEDULE:-cron(0 7 ? * MON *)}" ReportFailWeek="${REPORT_FAIL_WEEK:-}"
unset DATABASE_URL
save REPORTS_STACK "$REPORTS_STACK"

t aws cloudformation describe-stacks --stack-name "$REPORTS_STACK" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text

cat <<TXT

SES sandbox: open the "Amazon Web Services – Email Address Verification Request" email sent to
${RECIPIENTS%%,*} and click the link. With REPORT_SENDER_DOMAIN set, add the three DkimRecord
CNAMEs above at your DNS provider and wait for the domain to show "Verified".

Then: make report-now WEEK=<last ISO week, e.g. 2026-W40>
TXT
