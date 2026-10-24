#!/usr/bin/env bash
# Lab 7, Part 2, end of Step 3: tidy up what CloudFormation left behind, after the first
# `terraform apply` succeeded and the next plan says "No changes".
#   - Lambda permissions with CloudFormation's random statement ids (Terraform made its own)
#   - the deploy role's read-spry-auth / read-spry-ai policies (DescribeStacks on deleted stacks)
#   - infra/imports.tf and infra/generated.tf
source "$(dirname "$0")/../aws/env.sh"
cd "$(dirname "$0")/../.."
KEEP='^(AllowS3InvokeFromReportsBucket|AllowPublicFunctionUrl|AllowInvokeViaFunctionUrl)$'

for FN in spry-report-mailer spry-agenda-parser; do
  step "Old permissions on $FN"
  SIDS=$(t aws lambda get-policy --function-name "$FN" --query Policy --output text 2>/dev/null \
    | jq -r '.Statement[].Sid' | tr -d '\r' | grep -Ev "$KEEP" || true)
  [[ -z "$SIDS" ]] && echo "   none"
  for SID in $SIDS; do
    aws lambda remove-permission --function-name "$FN" --statement-id "$SID" && echo "   removed $SID"
  done
done

step "Deploy role: drop the CloudFormation read policies"
for POL in read-spry-auth read-spry-ai; do
  aws iam delete-role-policy --role-name "$DEPLOY_ROLE" --policy-name "$POL" 2>/dev/null \
    && echo "   removed $POL" || echo "   $POL: not there"
done

step "Import helpers"
rm -fv infra/imports.tf infra/generated.tf

cat <<'TXT'

Now run `terraform plan` once more: still "No changes." (removed permissions were never in the
state). Commit, then connect the workspace to GitHub (docs/LAB7.md, Step 4).
TXT
