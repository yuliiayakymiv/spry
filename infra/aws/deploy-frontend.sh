#!/usr/bin/env bash
# Build the frontend against the deployed API, upload it to S3, invalidate CloudFront.
# Called by `make deploy-frontend` — locally (Git Bash / WSL) and in GitHub Actions.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # otherwise Git Bash turns --paths "/*" into a Windows path

: "${S3_BUCKET:?}" "${CLOUDFRONT_DISTRIBUTION_ID:?}"
# Empty VITE_API_URL = the app calls /api on its own origin (CloudFront forwards it to the ALB).
VITE_API_URL="${VITE_API_URL:-}"

# Sign-in settings and the parser URL come from Terraform (infra/publish.tf puts its outputs into
# SSM under /spry/infra/), never copy-pasted. None of them is secret: they end up in the public
# JavaScript anyway. Missing values (infrastructure not applied yet) mean "feature hidden".
infra_out() {
  aws ssm get-parameter --name "/spry/infra/$1" --query Parameter.Value --output text 2>/dev/null \
    | tr -d '\r' || true
}
VITE_COGNITO_AUTHORITY=$(infra_out cognito_authority)
VITE_COGNITO_CLIENT_ID=$(infra_out cognito_client_id)
VITE_COGNITO_DOMAIN=$(infra_out cognito_domain)
if [[ -n "$VITE_COGNITO_CLIENT_ID" ]]; then
  echo "==> Sign-in: $VITE_COGNITO_DOMAIN (client $VITE_COGNITO_CLIENT_ID)"
else
  echo "==> /spry/infra/* not found: building without sign-in"
fi

# Lab 6: the agenda parser's function URL. Empty = the Paste box is hidden.
VITE_PARSER_URL=$(infra_out parser_url)
echo "==> Agenda parser: ${VITE_PARSER_URL:-<not deployed, Paste an agenda hidden>}"

echo "==> Building frontend (VITE_API_URL=${VITE_API_URL:-<same origin>})"
(cd frontend && npm ci && VITE_API_URL="$VITE_API_URL" \
  VITE_COGNITO_AUTHORITY="${VITE_COGNITO_AUTHORITY:-}" \
  VITE_COGNITO_CLIENT_ID="${VITE_COGNITO_CLIENT_ID:-}" \
  VITE_COGNITO_DOMAIN="${VITE_COGNITO_DOMAIN:-}" \
  VITE_PARSER_URL="${VITE_PARSER_URL:-}" npm run build)

echo "==> Uploading to s3://$S3_BUCKET"
# Hashed assets never change → cache for a year. index.html must always be revalidated.
aws s3 sync frontend/dist "s3://$S3_BUCKET" --delete --exclude index.html \
  --cache-control "public,max-age=31536000,immutable"
aws s3 cp frontend/dist/index.html "s3://$S3_BUCKET/index.html" --cache-control "no-cache"

echo "==> Invalidating CloudFront cache"
aws cloudfront create-invalidation --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --paths "/*" --query Invalidation.Id --output text
