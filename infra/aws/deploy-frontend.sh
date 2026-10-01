#!/usr/bin/env bash
# Build the frontend against the deployed API, upload it to S3, invalidate CloudFront.
# Called by `make deploy-frontend` — locally (Git Bash / WSL) and in GitHub Actions.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # otherwise Git Bash turns --paths "/*" into a Windows path

: "${S3_BUCKET:?}" "${CLOUDFRONT_DISTRIBUTION_ID:?}"
# Empty VITE_API_URL = the app calls /api on its own origin (CloudFront forwards it to the ALB).
VITE_API_URL="${VITE_API_URL:-}"

# Sign-in settings come from the auth stack's outputs (infra/auth.yml), never copy-pasted.
# None of them is secret: they end up in the public JavaScript anyway.
AUTH_STACK="${AUTH_STACK:-spry-auth}"
output() {
  aws cloudformation describe-stacks --stack-name "$AUTH_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text 2>/dev/null | tr -d '\r'
}
if aws cloudformation describe-stacks --stack-name "$AUTH_STACK" >/dev/null 2>&1; then
  VITE_COGNITO_AUTHORITY=$(output Authority)
  VITE_COGNITO_CLIENT_ID=$(output UserPoolClientId)
  VITE_COGNITO_DOMAIN=$(output CognitoDomain)
  echo "==> Sign-in: $VITE_COGNITO_DOMAIN (client $VITE_COGNITO_CLIENT_ID)"
else
  echo "==> Stack $AUTH_STACK not found: building without sign-in"
fi

echo "==> Building frontend (VITE_API_URL=${VITE_API_URL:-<same origin>})"
(cd frontend && npm ci && VITE_API_URL="$VITE_API_URL" \
  VITE_COGNITO_AUTHORITY="${VITE_COGNITO_AUTHORITY:-}" \
  VITE_COGNITO_CLIENT_ID="${VITE_COGNITO_CLIENT_ID:-}" \
  VITE_COGNITO_DOMAIN="${VITE_COGNITO_DOMAIN:-}" npm run build)

echo "==> Uploading to s3://$S3_BUCKET"
# Hashed assets never change → cache for a year. index.html must always be revalidated.
aws s3 sync frontend/dist "s3://$S3_BUCKET" --delete --exclude index.html \
  --cache-control "public,max-age=31536000,immutable"
aws s3 cp frontend/dist/index.html "s3://$S3_BUCKET/index.html" --cache-control "no-cache"

echo "==> Invalidating CloudFront cache"
aws cloudfront create-invalidation --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --paths "/*" --query Invalidation.Id --output text
