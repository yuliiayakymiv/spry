#!/usr/bin/env bash
# Point the two image Lambdas (report-builder, agenda-parser) at the image the API runs now.
# The image is the application road; Terraform ignores image_uri (lifecycle in infra/*.tf) and
# owns everything else. Run after a backend deploy that changed app/reports or app/ai:
#   make lambda-images
# (Before Lab 7 this was part of 09-reports.sh / 10-ai.sh.)
source "$(dirname "$0")/env.sh"

TASKDEF=$(t aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --query 'services[0].taskDefinition' --output text)
IMAGE_URI=$(t aws ecs describe-task-definition --task-definition "$TASKDEF" \
  --query "taskDefinition.containerDefinitions[?name=='$CONTAINER_NAME'].image | [0]" --output text)
echo "   image: $IMAGE_URI"

for FN in spry-report-builder spry-agenda-parser; do
  step "$FN"
  aws lambda update-function-code --function-name "$FN" --image-uri "$IMAGE_URI" \
    --query LastUpdateStatus --output text
  aws lambda wait function-updated --function-name "$FN"
done
