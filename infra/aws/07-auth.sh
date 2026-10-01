#!/usr/bin/env bash
# Sign-in with Cognito (Lab 4): email + password and "Continue with Google".
#   1. deploys infra/auth.yml as the CloudFormation stack spry-auth
#   2. lets CloudFront serve index.html for app routes such as /login/ (CloudFront Function)
#   3. lets the GitHub deploy role read the stack outputs, so CI builds with the same values
# Needs in the repo-root .env (git-ignored, never committed):
#   COGNITO_DOMAIN_PREFIX=spry-yourname   GOOGLE_CLIENT_ID=…   GOOGLE_CLIENT_SECRET=…
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/../.."
: "${CF_DIST_ID:?run 05-frontend.sh first}" "${CF_DOMAIN:?run 05-frontend.sh first}"

envval() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"'; }
PREFIX="${COGNITO_DOMAIN_PREFIX:-$(envval COGNITO_DOMAIN_PREFIX)}"
GID="${GOOGLE_CLIENT_ID:-$(envval GOOGLE_CLIENT_ID)}"
GSECRET="${GOOGLE_CLIENT_SECRET:-$(envval GOOGLE_CLIENT_SECRET)}"
: "${PREFIX:?set COGNITO_DOMAIN_PREFIX in .env}" "${GID:?set GOOGLE_CLIENT_ID in .env}" \
  "${GSECRET:?set GOOGLE_CLIENT_SECRET in .env}"
AUTH_STACK="${AUTH_STACK:-spry-auth}"
SITE_URL="https://$CF_DOMAIN"

step "CloudFormation stack $AUTH_STACK (user pool, Google IdP, app client, domain $PREFIX)"
aws cloudformation deploy --stack-name "$AUTH_STACK" --template-file infra/auth.yml \
  --no-fail-on-empty-changeset --tags PROJECT_NAME=spry \
  --parameter-overrides DomainPrefix="$PREFIX" SiteUrl="$SITE_URL" \
    GoogleClientId="$GID" GoogleClientSecret="$GSECRET"
save AUTH_STACK "$AUTH_STACK"

step "CloudFront Function: /login/ and other app routes -> /index.html"
FN=spry-spa-routes
cat > fn.rendered.js <<'JS'
function handler(event) {
  var request = event.request;
  // Files (/assets/x.js, /favicon.svg) pass through; app routes (/login/) get the SPA shell.
  if (request.uri.indexOf('.') === -1) request.uri = '/index.html';
  return request;
}
JS
FN_CONFIG="Comment=Spry SPA routes,Runtime=cloudfront-js-2.0"
if ETAG=$(t aws cloudfront describe-function --name "$FN" --query ETag --output text 2>/dev/null); then
  ETAG=$(t aws cloudfront update-function --name "$FN" --if-match "$ETAG" \
    --function-config "$FN_CONFIG" --function-code fileb://fn.rendered.js --query ETag --output text)
else
  ETAG=$(t aws cloudfront create-function --name "$FN" \
    --function-config "$FN_CONFIG" --function-code fileb://fn.rendered.js --query ETag --output text)
fi
rm -f fn.rendered.js
aws cloudfront publish-function --name "$FN" --if-match "$ETAG" >/dev/null
FN_ARN=$(t aws cloudfront describe-function --name "$FN" --stage LIVE \
  --query FunctionSummary.FunctionMetadata.FunctionARN --output text)

step "Attach it to the default (S3) behaviour of $CF_DIST_ID — /api/* is left alone"
DIST_ETAG=$(t aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query ETag --output text)
aws cloudfront get-distribution-config --id "$CF_DIST_ID" --query DistributionConfig --output json \
  | tr -d '\r' \
  | jq --arg arn "$FN_ARN" '.DefaultCacheBehavior.FunctionAssociations =
      {Quantity: 1, Items: [{EventType: "viewer-request", FunctionARN: $arn}]}' > dist.rendered.json
aws cloudfront update-distribution --id "$CF_DIST_ID" --if-match "$DIST_ETAG" \
  --distribution-config file://dist.rendered.json --query Distribution.Status --output text
rm -f dist.rendered.json

step "Deploy role may read the auth stack outputs (CI builds the frontend with them)"
if aws iam get-role --role-name "$DEPLOY_ROLE" >/dev/null 2>&1; then
  aws iam put-role-policy --role-name "$DEPLOY_ROLE" --policy-name read-spry-auth --policy-document \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"cloudformation:DescribeStacks\",\"Resource\":\"arn:aws:cloudformation:$AWS_REGION:$ACCOUNT_ID:stack/$AUTH_STACK/*\"}]}"
fi

step "Rebuild the frontend with the Cognito settings"
S3_BUCKET="$S3_BUCKET" CLOUDFRONT_DISTRIBUTION_ID="$CF_DIST_ID" AUTH_STACK="$AUTH_STACK" \
  bash infra/aws/deploy-frontend.sh

REDIRECT=$(t aws cloudformation describe-stacks --stack-name "$AUTH_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='GoogleRedirectUri'].OutputValue" --output text)
cat <<TXT

Google OAuth client must have (Google Cloud console → Clients → your Web client):
  Authorised JavaScript origin:  https://$PREFIX.auth.$AWS_REGION.amazoncognito.com
  Authorised redirect URI:       $REDIRECT
Consent screen: External, scopes openid/email/profile only, status "In production".

Login page to submit:  $SITE_URL/login/
(CloudFront needs a few minutes to roll out the function before /login/ works.)
TXT
