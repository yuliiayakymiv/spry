#!/usr/bin/env bash
# Lab 7, Part 2, Step 3a + 3b, run ONCE from Git Bash in the repo root (your own AWS credentials):
#   1. marks every resource of spry-auth, spry-reports, spry-ai as DeletionPolicy: Retain
#      (takes the template that is deployed now, adds Retain, updates the stack with the same
#      parameter values) and checks that AWS really stored it;
#   2. reads the real IDs and settings from AWS and writes
#        infra/imports.tf        import blocks (deleted again after the migration)
#        infra/terraform.tfvars  non-secret values, exactly as they are in AWS today
# It deletes nothing. Deleting the stacks is 2-delete-stacks.sh.
source "$(dirname "$0")/../aws/env.sh"
cd "$(dirname "$0")/../.."
PY="${PYTHON:-python}"
command -v "$PY" >/dev/null || PY=python3
P=spry
STACKS=(spry-auth spry-reports spry-ai)

retained() { # stack -> "resources retained" count check
  local stack=$1 total retain
  total=$(t aws cloudformation describe-stack-resources --stack-name "$stack" \
    --query 'length(StackResources)' --output text)
  retain=$(t aws cloudformation get-template --stack-name "$stack" --template-stage Original \
    --query TemplateBody --output text | grep -c "DeletionPolicy: Retain" || true)
  echo "$retain/$total"
  [[ "$retain" -ge "$total" ]]
}

for STACK in "${STACKS[@]}"; do
  step "Retain: $STACK"
  if retained "$STACK" >/dev/null; then echo "   already retained ($(retained "$STACK"))"; continue; fi
  t aws cloudformation get-template --stack-name "$STACK" --template-stage Original \
    --query TemplateBody --output text | "$PY" infra/migrate/add-retain.py > "infra/migrate/.$STACK.yml"
  # Same parameter values as now (NoEcho ones included), same tags: only the policies change.
  PARAMS=$(t aws cloudformation describe-stacks --stack-name "$STACK" \
    --query 'Stacks[0].Parameters[].ParameterKey' --output text \
    | tr '\t' '\n' | sed 's/.*/ParameterKey=&,UsePreviousValue=true/' | tr '\n' ' ')
  # shellcheck disable=SC2086
  aws cloudformation update-stack --stack-name "$STACK" \
    --template-body "file://infra/migrate/.$STACK.yml" \
    --capabilities CAPABILITY_NAMED_IAM --parameters $PARAMS --query StackId --output text
  aws cloudformation wait stack-update-complete --stack-name "$STACK"
  rm -f "infra/migrate/.$STACK.yml"
  retained "$STACK" >/dev/null || { echo "!! $STACK: Retain not stored ($(retained "$STACK")). Stop."; exit 1; }
  echo "   ok: $(retained "$STACK") resources retained"
done

step "Reading real IDs and settings from AWS"
q() { t aws "$@" --output text; }
envval() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"'; }

POOL_ID=$(q cognito-idp list-user-pools --max-results 60 --query "UserPools[?Name=='$P-users'].Id | [0]")
CLIENT_ID=$(q cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" \
  --query "UserPoolClients[?ClientName=='$P-web'].ClientId | [0]")
PREFIX=$(q cognito-idp describe-user-pool --user-pool-id "$POOL_ID" --query UserPool.Domain)
BRANDING_ID=$(q cognito-idp describe-managed-login-branding-by-client --user-pool-id "$POOL_ID" \
  --client-id "$CLIENT_ID" --query ManagedLoginBranding.ManagedLoginBrandingId)
SITE_URL=$(q cognito-idp describe-user-pool-client --user-pool-id "$POOL_ID" --client-id "$CLIENT_ID" \
  --query "UserPoolClient.CallbackURLs[?starts_with(@, 'https://')] | [0]")
SITE_URL="${SITE_URL%/}"
GOOGLE_ID=$(q cognito-idp describe-identity-provider --user-pool-id "$POOL_ID" --provider-name Google \
  --query IdentityProvider.ProviderDetails.client_id)

VPC=$(q ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')
VPCE=$(q ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" \
  "Name=service-name,Values=com.amazonaws.$AWS_REGION.s3" Name=vpc-endpoint-type,Values=Gateway \
  --query 'VpcEndpoints[0].VpcEndpointId')
QURL=$(q sqs get-queue-url --queue-name "$P-report-requests" --query QueueUrl)
DLQURL=$(q sqs get-queue-url --queue-name "$P-report-requests-dlq" --query QueueUrl)
ESM=$(q lambda list-event-source-mappings --function-name "$P-report-builder" \
  --query 'EventSourceMappings[0].UUID')

fenv() { q lambda get-function-configuration --function-name "$1" --query "Environment.Variables.$2"; }
RECIPIENTS=$(fenv "$P-report-mailer" RECIPIENTS)
SENDER=$(fenv "$P-report-mailer" SENDER)
FAIL_WEEK=$(fenv "$P-report-builder" REPORT_FAIL_WEEK); [[ "$FAIL_WEEK" == "None" ]] && FAIL_WEEK=""
MODEL=$(fenv "$P-agenda-parser" PARSER_MODEL)
BEDROCK=$(fenv "$P-agenda-parser" BEDROCK_REGION)
SENDER_DOMAIN=""
[[ "$SENDER" == reports@* && "$SENDER" != "${RECIPIENTS%%,*}" ]] && SENDER_DOMAIN="${SENDER#reports@}"
SCHEDULE=$(q scheduler get-schedule --name "$P-weekly-report" --query ScheduleExpression)
BUDGET_USD=$(q budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$P-monthly" \
  --query Budget.BudgetLimit.Amount)
BUDGET_USD=$(printf '%g' "$BUDGET_USD")
BUDGET_EMAIL="${BUDGET_EMAIL:-$(envval BUDGET_EMAIL)}"
: "${BUDGET_EMAIL:?set BUDGET_EMAIL in .env (where the budget alert goes)}"

for v in POOL_ID CLIENT_ID PREFIX BRANDING_ID SITE_URL GOOGLE_ID VPCE QURL DLQURL ESM RECIPIENTS; do
  [[ -n "${!v}" && "${!v}" != "None" ]] || { echo "!! could not read $v"; exit 1; }
  printf '   %-12s %s\n' "$v" "${!v}"
done

step "Writing infra/terraform.tfvars"
cat > infra/terraform.tfvars <<TF
# Non-secret values only. The Google client secret is a sensitive variable in the
# HCP Terraform workspace. Generated from the live resources by infra/migrate/1-retain-and-collect.sh.
project_name = "$P"
region       = "$AWS_REGION"

# auth.tf
cognito_domain_prefix = "$PREFIX"
site_url              = "$SITE_URL"
google_client_id      = "$GOOGLE_ID"

# reports.tf
report_recipients    = "$RECIPIENTS"
report_sender_domain = "$SENDER_DOMAIN"
report_schedule      = "$SCHEDULE"
report_fail_week     = "$FAIL_WEEK"

# ai.tf
parser_model   = "$MODEL"
bedrock_region = "$BEDROCK"
budget_email   = "$BUDGET_EMAIL"
budget_usd     = $BUDGET_USD
TF

step "Writing infra/imports.tf"
imp() { printf 'import {\n  to = %s\n  id = "%s"\n}\n\n' "$1" "$2"; }
B="$P-reports-$ACCOUNT_ID"
{
  echo "# Generated by infra/migrate/1-retain-and-collect.sh. Delete this file after the migration."
  echo
  echo "# ---- auth (was stack spry-auth)"
  imp aws_cognito_user_pool.main "$POOL_ID"
  imp aws_cognito_identity_provider.google "$POOL_ID:Google"
  imp aws_cognito_user_pool_client.web "$POOL_ID/$CLIENT_ID"
  imp aws_cognito_user_pool_domain.main "$PREFIX"
  imp aws_cognito_managed_login_branding.main "$POOL_ID,$BRANDING_ID"
  echo "# ---- reports (was stack spry-reports)"
  imp aws_s3_bucket.reports "$B"
  imp aws_s3_bucket_public_access_block.reports "$B"
  imp aws_s3_bucket_ownership_controls.reports "$B"
  imp aws_s3_bucket_lifecycle_configuration.reports "$B"
  imp aws_s3_bucket_notification.reports "$B"
  imp aws_vpc_endpoint.s3 "$VPCE"
  imp aws_sqs_queue.report_requests_dlq "$DLQURL"
  imp aws_sqs_queue.report_requests "$QURL"
  imp aws_cloudwatch_log_group.report_builder "/aws/lambda/$P-report-builder"
  imp aws_iam_role.report_builder "$P-report-builder"
  imp aws_iam_role_policy_attachment.report_builder_vpc \
    "$P-report-builder/arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  imp aws_iam_role_policy.report_builder "$P-report-builder:build-reports"
  imp aws_lambda_function.report_builder "$P-report-builder"
  imp aws_lambda_event_source_mapping.report_builder "$ESM"
  imp aws_iam_role.report_scheduler "$P-report-scheduler"
  imp aws_iam_role_policy.report_scheduler "$P-report-scheduler:send-report-requests"
  imp aws_scheduler_schedule.weekly_report "default/$P-weekly-report"
  imp aws_cloudwatch_log_group.report_mailer "/aws/lambda/$P-report-mailer"
  imp aws_iam_role.report_mailer "$P-report-mailer"
  imp aws_iam_role_policy_attachment.report_mailer_logs \
    "$P-report-mailer/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  imp aws_iam_role_policy.report_mailer "$P-report-mailer:mail-reports"
  imp aws_lambda_function.report_mailer "$P-report-mailer"
  imp aws_sesv2_email_identity.recipient "${RECIPIENTS%%,*}"
  [[ -n "$SENDER_DOMAIN" ]] && imp 'aws_sesv2_email_identity.domain[0]' "$SENDER_DOMAIN"
  echo "# ---- ai (was stack spry-ai)"
  imp aws_cloudwatch_log_group.agenda_parser "/aws/lambda/$P-agenda-parser"
  imp aws_iam_role.agenda_parser "$P-agenda-parser"
  imp aws_iam_role_policy_attachment.agenda_parser_logs \
    "$P-agenda-parser/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  imp aws_iam_role_policy.agenda_parser "$P-agenda-parser:call-claude"
  imp aws_lambda_function.agenda_parser "$P-agenda-parser"
  imp aws_lambda_function_url.agenda_parser "$P-agenda-parser"
  imp aws_budgets_budget.monthly "$ACCOUNT_ID:$P-monthly"
  echo "# Not imported, created fresh (child resources, safe to re-create):"
  echo "#   aws_lambda_permission.mailer_s3, .parser_url, .parser_invoke  (new statement ids)"
  echo "#   aws_ssm_parameter.published[*], aws_iam_role_policy.deploy_reads_infra (new, publish.tf)"
} > infra/imports.tf
echo "   $(grep -c '^import' infra/imports.tf) import blocks"

cat <<TXT

Done. Nothing was deleted. Next:
  1. Check infra/terraform.tfvars, commit it (and infra/imports.tf for now).
  2. bash infra/migrate/2-delete-stacks.sh
TXT
