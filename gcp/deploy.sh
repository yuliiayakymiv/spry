#!/usr/bin/env bash
# The application road on Google Cloud (Terraform in gcp/ owns the infrastructure).
# Run from the repo root in Cloud Shell (gcloud, docker-free: the image is built by Cloud Build):
#   PROJECT_ID=spry-... COGNITO_AUTHORITY=... COGNITO_CLIENT_ID=... COGNITO_DOMAIN=... bash gcp/deploy.sh
#   bash gcp/deploy.sh backend    # only the API     |   bash gcp/deploy.sh frontend   # only the site
set -euo pipefail
: "${PROJECT_ID:?set PROJECT_ID}"
REGION=${REGION:-europe-west1}
WHAT=${1:-all}
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/spry/api:$(git rev-parse --short HEAD)"

if [[ $WHAT == all || $WHAT == backend ]]; then
  echo "== API: Cloud Build -> Artifact Registry -> Cloud Run"
  gcloud builds submit backend --project "$PROJECT_ID" --region "$REGION" --tag "$IMAGE"
  # Same image as on AWS: no Lambda adapter, uvicorn listens on $PORT.
  gcloud run deploy spry-api --project "$PROJECT_ID" --region "$REGION" --image "$IMAGE" --quiet
fi

if [[ $WHAT == all || $WHAT == frontend ]]; then
  : "${COGNITO_AUTHORITY:?}" "${COGNITO_CLIENT_ID:?}" "${COGNITO_DOMAIN:?}"
  echo "== Site: static build -> Firebase Hosting (/api/** rewritten to Cloud Run)"
  cd frontend
  npm ci --no-audit --no-fund
  # VITE_API_URL empty: the site calls /api on its own origin. The agenda parser stays on AWS.
  VITE_API_URL="" VITE_COGNITO_AUTHORITY="$COGNITO_AUTHORITY" VITE_COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
    VITE_COGNITO_DOMAIN="$COGNITO_DOMAIN" VITE_PARSER_URL="${PARSER_URL:-}" npm run build
  npx -y firebase-tools@14 deploy --only hosting --project "$PROJECT_ID" --non-interactive
fi
echo "Site: https://$PROJECT_ID.web.app"
