#!/usr/bin/env bash
# Let GitHub Actions deploy WITHOUT stored keys: trust GitHub's OIDC tokens, but only from
# the main branch of $GITHUB_REPO, and give that role only what the deploy needs.
source "$(dirname "$0")/env.sh"
: "${S3_BUCKET:?run 05-frontend.sh first}" "${CF_DIST_ID:?run 05-frontend.sh first}"
PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"

step "OIDC identity provider token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com --query OpenIDConnectProviderArn --output text
fi

# Since 15 July 2026 GitHub puts immutable IDs into the token's "sub" claim for new repos:
#   repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/main
# Older repos still send repo:<owner>/<repo>:ref:refs/heads/main. We accept both, main only.
OWNER="${GITHUB_REPO%%/*}"; REPO="${GITHUB_REPO##*/}"
IDS=$(curl -fsS "https://api.github.com/repos/$GITHUB_REPO" | jq -r '"\(.owner.id) \(.id)"' | tr -d '\r')
read -r OWNER_ID REPO_ID <<<"$IDS"
SUB_OLD="repo:$GITHUB_REPO:ref:refs/heads/main"
SUB_NEW="repo:$OWNER@$OWNER_ID/$REPO@$REPO_ID:ref:refs/heads/main"

step "Role $DEPLOY_ROLE — trusted only for the main branch of $GITHUB_REPO"
echo "   accepted sub claims: $SUB_OLD"
echo "                        $SUB_NEW"
TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Federated":"$PROVIDER_ARN"},
  "Action":"sts:AssumeRoleWithWebIdentity",
  "Condition":{"StringEquals":{
    "token.actions.githubusercontent.com:aud":"sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub":["$SUB_OLD","$SUB_NEW"]}}}]}
JSON
)
if aws iam get-role --role-name "$DEPLOY_ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$DEPLOY_ROLE" --policy-document "$TRUST"
else
  aws iam create-role --role-name "$DEPLOY_ROLE" --assume-role-policy-document "$TRUST" \
    --query Role.Arn --output text
fi

step "Permissions: push one ECR repo, roll one ECS service, sync one bucket, invalidate one CDN"
aws iam put-role-policy --role-name "$DEPLOY_ROLE" --policy-name deploy-spry --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
 {"Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload",
   "ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage","ecr:DescribeImages"],
  "Resource":"arn:aws:ecr:$AWS_REGION:$ACCOUNT_ID:repository/$ECR_REPOSITORY"},
 {"Effect":"Allow","Action":["ecs:DescribeTaskDefinition","ecs:RegisterTaskDefinition"],"Resource":"*"},
 {"Effect":"Allow","Action":["ecs:UpdateService","ecs:DescribeServices"],
  "Resource":"arn:aws:ecs:$AWS_REGION:$ACCOUNT_ID:service/$ECS_CLUSTER/$ECS_SERVICE"},
 {"Effect":"Allow","Action":"iam:PassRole","Resource":"arn:aws:iam::$ACCOUNT_ID:role/$EXEC_ROLE",
  "Condition":{"StringEquals":{"iam:PassedToService":"ecs-tasks.amazonaws.com"}}},
 {"Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::$S3_BUCKET"},
 {"Effect":"Allow","Action":["s3:PutObject","s3:DeleteObject","s3:GetObject"],"Resource":"arn:aws:s3:::$S3_BUCKET/*"},
 {"Effect":"Allow","Action":"cloudfront:CreateInvalidation",
  "Resource":"arn:aws:cloudfront::$ACCOUNT_ID:distribution/$CF_DIST_ID"}
]}
JSON
)"

ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$DEPLOY_ROLE"
save DEPLOY_ROLE_ARN "$ROLE_ARN"
cat <<TXT

Now add these as GitHub repository VARIABLES (not secrets — none of them is secret):
  GitHub → $GITHUB_REPO → Settings → Secrets and variables → Actions → Variables → New repository variable

  AWS_REGION                  $AWS_REGION
  AWS_DEPLOY_ROLE_ARN         $ROLE_ARN
  S3_BUCKET                   $S3_BUCKET
  CLOUDFRONT_DISTRIBUTION_ID  $CF_DIST_ID

Then push to main: the "deploy" jobs in .github/workflows/ci.yml will run.
TXT
