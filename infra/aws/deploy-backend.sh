#!/usr/bin/env bash
# Build the backend image, push it to ECR tagged with the commit SHA, roll the ECS service.
# Called by `make deploy-backend` — locally (Git Bash / WSL) and in GitHub Actions.
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: don't rewrite "/..." arguments into C:/ paths

: "${AWS_REGION:?}" "${ECR_REPOSITORY:?}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse HEAD)}"

# `tr -d '\r'`: aws.exe on Windows ends its text output with CRLF.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text | tr -d '\r')
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
IMAGE="$REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG"

echo "==> Logging in to $REGISTRY"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "==> Building $IMAGE"
docker build --platform linux/amd64 --provenance=false -t "$IMAGE" backend

echo "==> Pushing $IMAGE"
docker push "$IMAGE"

IMAGE="$IMAGE" bash "$(dirname "$0")/release-backend.sh"
