#!/usr/bin/env bash
# Point the ECS service at an image that is already in ECR, and wait until it is healthy.
# Used by deploy-backend.sh and by `make rollback-backend TAG=<sha>` (no rebuild).
set -euo pipefail
export MSYS_NO_PATHCONV=1

: "${AWS_REGION:?}" "${ECR_REPOSITORY:?}" "${ECS_CLUSTER:?}" "${ECS_SERVICE:?}"
: "${ECS_TASK_FAMILY:?}" "${CONTAINER_NAME:?}"

if [[ -z "${IMAGE:-}" ]]; then
  : "${IMAGE_TAG:?set IMAGE or IMAGE_TAG}"
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text | tr -d '\r')
  IMAGE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$IMAGE_TAG"
fi

echo "==> Registering a new revision of $ECS_TASK_FAMILY with $IMAGE"
# Start from the latest revision, so env vars, secrets and CPU/memory stay as configured.
TMP="infra/aws/.taskdef.rendered.json"
aws ecs describe-task-definition --task-definition "$ECS_TASK_FAMILY" \
    --query taskDefinition --output json \
  | jq --arg IMAGE "$IMAGE" --arg NAME "$CONTAINER_NAME" '
      .containerDefinitions |= map(if .name == $NAME then .image = $IMAGE else . end)
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
            .compatibilities, .registeredAt, .registeredBy)' > "$TMP"

ARN=$(aws ecs register-task-definition --cli-input-json "file://$TMP" \
  --query taskDefinition.taskDefinitionArn --output text | tr -d '\r')
rm -f "$TMP"
echo "    $ARN"

echo "==> Updating service $ECS_SERVICE"
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$ARN" --query service.serviceName --output text

# Blocks until new tasks pass the ALB health check and old ones are drained.
echo "==> Waiting for the service to become stable (a few minutes)…"
aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"
echo "==> Deployed $IMAGE"
