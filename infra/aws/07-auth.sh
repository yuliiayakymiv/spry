#!/usr/bin/env bash
# Sign-in routing (Lab 4). The Cognito user pool, Google IdP, app client and domain are
# Terraform now (infra/auth.tf, applied by HCP Terraform). This script does the rest:
#   1. lets CloudFront serve index.html for app routes such as /login/ (CloudFront Function)
#   2. rebuilds the frontend with the Cognito values Terraform published to SSM
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/../.."
: "${CF_DIST_ID:?run 05-frontend.sh first}" "${CF_DOMAIN:?run 05-frontend.sh first}"
COGNITO_DOMAIN=$(infra_out cognito_domain)
: "${COGNITO_DOMAIN:?/spry/infra/cognito_domain not found — apply infra/ (Terraform) first}"
SITE_URL="https://$CF_DOMAIN"

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

step "Rebuild the frontend with the Cognito settings"
S3_BUCKET="$S3_BUCKET" CLOUDFRONT_DISTRIBUTION_ID="$CF_DIST_ID" bash infra/aws/deploy-frontend.sh

REDIRECT="$COGNITO_DOMAIN/oauth2/idpresponse"
cat <<TXT

Google OAuth client must have (Google Cloud console → Clients → your Web client):
  Authorised JavaScript origin:  $COGNITO_DOMAIN
  Authorised redirect URI:       $REDIRECT
Consent screen: External, scopes openid/email/profile only, status "In production".

Login page to submit:  $SITE_URL/login/
(CloudFront needs a few minutes to roll out the function before /login/ works.)
TXT
