#!/usr/bin/env bash
# Shared settings for the one-time setup scripts 01-…06-. Sourced, not run.
set -euo pipefail
export MSYS_NO_PATHCONV=1         # Git Bash: keep "/ecs/…", "/*" etc. as written
export AWS_PAGER=""               # never open a pager on Windows
export AWS_REGION="${AWS_REGION:-eu-central-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

export GITHUB_REPO="${GITHUB_REPO:-yuliiayakymiv/spry}"
export ECR_REPOSITORY=spry-backend ECS_CLUSTER=spry ECS_SERVICE=spry-backend
export ECS_TASK_FAMILY=spry-backend CONTAINER_NAME=spry-backend
export DB_INSTANCE=spry-db DB_NAME=meetings DB_USER=meetings
export EXEC_ROLE=spry-ecs-task-execution DEPLOY_ROLE=spry-github-deploy

# IDs created by earlier scripts are remembered here (git-ignored, contains your account id).
STATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state"
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"

# Run a command and strip the CR that aws.exe / jq.exe add on Windows.
t() { "$@" | tr -d '\r'; }

# Remember a value for the next scripts: save NAME value
save() {
  touch "$STATE_FILE"
  grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  printf '%s="%s"\n' "$1" "$2" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  export "$1=$2"
}

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

ACCOUNT_ID=$(t aws sts get-caller-identity --query Account --output text)
export ACCOUNT_ID
export REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
echo "AWS account $ACCOUNT_ID, region $AWS_REGION"
