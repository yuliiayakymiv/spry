#!/usr/bin/env bash
# Lab 7, Part 2, Step 3a: delete the three CloudFormation stacks, KEEP their resources.
# Refuses to delete a stack whose deployed template is not fully Retain (1-retain-and-collect.sh).
source "$(dirname "$0")/../aws/env.sh"
cd "$(dirname "$0")/../.."
STACKS=(spry-ai spry-reports spry-auth)

for STACK in "${STACKS[@]}"; do
  aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1 \
    || { echo "   $STACK: already gone"; continue; }
  total=$(t aws cloudformation describe-stack-resources --stack-name "$STACK" \
    --query 'length(StackResources)' --output text)
  retain=$(t aws cloudformation get-template --stack-name "$STACK" --template-stage Original \
    --query TemplateBody --output text | grep -c "DeletionPolicy: Retain" || true)
  [[ "$retain" -ge "$total" ]] || { echo "!! $STACK: only $retain/$total retained. Run 1-retain-and-collect.sh"; exit 1; }
done

read -r -p "Delete stacks ${STACKS[*]} (resources stay)? Type 'retain': " ok
[[ "$ok" == "retain" ]] || { echo "Cancelled."; exit 1; }

for STACK in "${STACKS[@]}"; do
  aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1 || continue
  step "Deleting stack $STACK"
  aws cloudformation delete-stack --stack-name "$STACK"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK"
done

step "The resources must still be there, now owned by nobody"
POOL=$(t aws cognito-idp list-user-pools --max-results 60 --query "UserPools[?Name=='spry-users'].Id | [0]" --output text)
USERS=$(t aws cognito-idp describe-user-pool --user-pool-id "$POOL" --query UserPool.EstimatedNumberOfUsers --output text)
echo "   user pool $POOL: ~$USERS users"
aws s3api head-bucket --bucket "spry-reports-$ACCOUNT_ID" && echo "   bucket spry-reports-$ACCOUNT_ID: ok"
aws lambda get-function --function-name spry-agenda-parser --query Configuration.State --output text \
  | sed 's/^/   spry-agenda-parser: /'

cat <<'TXT'

Next (Part 2, Step 3c), from infra/ with `terraform login` done and the workspace variables set:
  terraform init
  terraform plan          # goal: N to import, only the expected adds/changes (docs/LAB7.md)
  terraform apply
  terraform plan          # must end with "No changes." -> save the output (submission item 3)
Then: bash infra/migrate/3-after-apply.sh
TXT
