#!/usr/bin/env bash
# ECR repository + the first backend image, tagged with the current commit SHA.
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/../.."

step "ECR repository $ECR_REPOSITORY"
if ! aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" >/dev/null 2>&1; then
  aws ecr create-repository --repository-name "$ECR_REPOSITORY" \
    --image-scanning-configuration scanOnPush=true --query repository.repositoryUri --output text
fi

TAG=$(git rev-parse HEAD)
IMAGE="$REGISTRY/$ECR_REPOSITORY:$TAG"
step "Building and pushing $IMAGE"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker build --platform linux/amd64 --provenance=false -t "$IMAGE" backend
docker push "$IMAGE"
save FIRST_IMAGE "$IMAGE"
echo "Done. Next: bash infra/aws/04-ecs.sh"
