#!/usr/bin/env bash
# Paste an agenda (Lab 6): deploys infra/ai.yml as the CloudFormation stack spry-ai.
# Run AFTER a backend image with app/ai and anthropic[bedrock] is deployed (push to main → CI,
# or `make deploy-backend`): the parser Lambda reuses the image the ECS service runs now.
# Re-run it after every change to backend/app/ai/, so the Lambda picks up the new image.
# Needs in the repo-root .env (git-ignored):
#   BUDGET_EMAIL=you@example.com             where the budget alert goes
# Optional: PARSER_MODEL=us.amazon.nova-lite-v1:0 BUDGET_USD=50 make deploy-ai
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/../.."
: "${CF_DOMAIN:?run 05-frontend.sh first, or pass the site: CF_DOMAIN=dxxxx.cloudfront.net make deploy-ai}"

envval() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"'; }
BUDGET_EMAIL="${BUDGET_EMAIL:-$(envval BUDGET_EMAIL)}"
: "${BUDGET_EMAIL:?set BUDGET_EMAIL in .env}"
AI_STACK="${AI_STACK:-spry-ai}"
AUTH_STACK="${AUTH_STACK:-spry-auth}"

step "Inputs"
TASKDEF=$(t aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].taskDefinition' --output text)
IMAGE_URI=$(t aws ecs describe-task-definition --task-definition "$TASKDEF" \
  --query "taskDefinition.containerDefinitions[?name=='$CONTAINER_NAME'].image | [0]" --output text)
auth_out() {
  t aws cloudformation describe-stacks --stack-name "$AUTH_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
ISSUER=$(auth_out Authority)
CLIENT_ID=$(auth_out UserPoolClientId)
: "${ISSUER:?stack $AUTH_STACK not found — run 07-auth.sh first}" "${CLIENT_ID:?}"
echo "   image:   $IMAGE_URI"
echo "   site:    https://$CF_DOMAIN"
echo "   issuer:  $ISSUER"
echo "   model:   ${PARSER_MODEL:-us.amazon.nova-pro-v1:0}"

step "CloudFormation stack $AI_STACK (parser Lambda + function URL, budget alert)"
aws cloudformation deploy --stack-name "$AI_STACK" --template-file infra/ai.yml \
  --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset --tags PROJECT_NAME=spry \
  --parameter-overrides ImageUri="$IMAGE_URI" SiteUrl="https://$CF_DOMAIN" \
    CognitoIssuer="$ISSUER" CognitoClientId="$CLIENT_ID" \
    ParserModel="${PARSER_MODEL:-us.amazon.nova-pro-v1:0}" BedrockRegion="${BEDROCK_REGION:-us-east-1}" \
    BudgetEmail="$BUDGET_EMAIL" BudgetUsd="${BUDGET_USD:-5}"
save AI_STACK "$AI_STACK"

# CloudFormation does not replace the code when the image URI is unchanged but the tag moved;
# point the function at the exact image explicitly.
aws lambda update-function-code --function-name spry-agenda-parser --image-uri "$IMAGE_URI" \
  --query LastUpdateStatus --output text >/dev/null
aws lambda wait function-updated --function-name spry-agenda-parser

step "Let the GitHub deploy role read this stack's outputs (frontend build needs ParserUrl)"
aws iam put-role-policy --role-name "$DEPLOY_ROLE" --policy-name read-spry-ai --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"cloudformation:DescribeStacks\",\"Resource\":\"arn:aws:cloudformation:$AWS_REGION:$ACCOUNT_ID:stack/$AI_STACK/*\"}]}" \
  || echo "   (no $DEPLOY_ROLE role: skip, CI deploys only after 06-oidc.sh)"

PARSER_URL=$(t aws cloudformation describe-stacks --stack-name "$AI_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ParserUrl'].OutputValue" --output text)
save PARSER_URL "$PARSER_URL"

cat <<TXT

Parser URL: $PARSER_URL
  curl -i -X POST $PARSER_URL      → 401 (no token: the model is never called)

Next:
  1. make deploy-frontend S3_BUCKET=${S3_BUCKET:-<bucket>} CLOUDFRONT_DISTRIBUTION_ID=${CF_DIST_ID:-<distribution id>}
     (or push to main) — the build picks up VITE_PARSER_URL from this stack.
  2. AWS Budgets emails $BUDGET_EMAIL: no confirmation needed.
  3. Logs: aws logs tail /aws/lambda/spry-agenda-parser --follow --format short
TXT
