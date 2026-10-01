#!/usr/bin/env bash
# Build the frontend against the deployed API, upload it to S3, invalidate CloudFront.
# Called by `make deploy-frontend` — locally (Git Bash / WSL) and in GitHub Actions.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # otherwise Git Bash turns --paths "/*" into a Windows path

: "${S3_BUCKET:?}" "${CLOUDFRONT_DISTRIBUTION_ID:?}"
# Empty VITE_API_URL = the app calls /api on its own origin (CloudFront forwards it to the ALB).
VITE_API_URL="${VITE_API_URL:-}"

echo "==> Building frontend (VITE_API_URL=${VITE_API_URL:-<same origin>})"
(cd frontend && npm ci && VITE_API_URL="$VITE_API_URL" npm run build)

echo "==> Uploading to s3://$S3_BUCKET"
# Hashed assets never change → cache for a year. index.html must always be revalidated.
aws s3 sync frontend/dist "s3://$S3_BUCKET" --delete --exclude index.html \
  --cache-control "public,max-age=31536000,immutable"
aws s3 cp frontend/dist/index.html "s3://$S3_BUCKET/index.html" --cache-control "no-cache"

echo "==> Invalidating CloudFront cache"
aws cloudfront create-invalidation --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --paths "/*" --query Invalidation.Id --output text
