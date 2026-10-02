#!/usr/bin/env bash
# Turn on token checks in the API (Lab 4 stretch): give the ECS task the user pool's issuer
# and app client id, then roll the service. From then on every /api call (except /api/health)
# needs "Authorization: Bearer <Cognito access token>", and each user sees only their own data.
# Run AFTER the backend image with app/auth.py is deployed (push to main → CI), and after 07-auth.sh.
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/../.."
AUTH_STACK="${AUTH_STACK:-spry-auth}"

out() {
  t aws cloudformation describe-stacks --stack-name "$AUTH_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
ISSUER=$(out Authority)
CLIENT_ID=$(out UserPoolClientId)
: "${ISSUER:?stack $AUTH_STACK not found — run 07-auth.sh first}" "${CLIENT_ID:?}"
echo "   issuer:    $ISSUER"
echo "   client id: $CLIENT_ID"

step "New task definition revision of $ECS_TASK_FAMILY with COGNITO_ISSUER / COGNITO_CLIENT_ID"
# Same image, CPU, secrets; only these two env vars are added or replaced. Later deploys
# (release-backend.sh) start from this revision, so the values stay.
TMP="infra/aws/.taskdef.rendered.json"
aws ecs describe-task-definition --task-definition "$ECS_TASK_FAMILY" --query taskDefinition --output json \
  | tr -d '\r' \
  | jq --arg NAME "$CONTAINER_NAME" --arg ISS "$ISSUER" --arg CID "$CLIENT_ID" '
      .containerDefinitions |= map(if .name == $NAME then
          .environment = ([(.environment // [])[] | select(.name != "COGNITO_ISSUER" and .name != "COGNITO_CLIENT_ID")]
                          + [{name: "COGNITO_ISSUER", value: $ISS}, {name: "COGNITO_CLIENT_ID", value: $CID}])
        else . end)
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
            .compatibilities, .registeredAt, .registeredBy)' > "$TMP"
ARN=$(t aws ecs register-task-definition --cli-input-json "file://$TMP" \
  --query taskDefinition.taskDefinitionArn --output text)
rm -f "$TMP"
echo "   $ARN"

step "Roll $ECS_SERVICE and wait until it is healthy (a few minutes)"
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$ARN" --query service.serviceName --output text
aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"

cat <<TXT

API now requires sign-in. Check:
  curl -i https://${CF_DOMAIN:-<site>}/api/meetings      → 401
  curl -i https://${CF_DOMAIN:-<site>}/api/health        → 200
TXT
