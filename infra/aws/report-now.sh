#!/usr/bin/env bash
# Ask for a report on demand: puts the same message on the queue that the Monday schedule sends.
# Called by `make report-now WEEK=2026-W39` (empty WEEK = the builder picks last week).
set -euo pipefail
export MSYS_NO_PATHCONV=1 AWS_PAGER=""

: "${AWS_REGION:?}"
WEEK="${WEEK:-}"

if [[ -n "$WEEK" && ! "$WEEK" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
  echo "WEEK must look like 2026-W39, got '$WEEK'" >&2
  exit 1
fi

# From `terraform output -raw report_queue_url` (the Makefile passes it), else from SSM.
QUEUE_URL="${QUEUE_URL:-}"
if [[ -z "$QUEUE_URL" ]]; then
  QUEUE_URL=$(aws ssm get-parameter --region "$AWS_REGION" --name /spry/infra/report_queue_url \
    --query Parameter.Value --output text | tr -d '\r')
fi
if [[ -n "$WEEK" ]]; then
  BODY="{\"week\": \"$WEEK\", \"source\": \"make\"}"
else
  BODY='{"week": null, "source": "make"}'
fi

echo "==> $BODY → $QUEUE_URL"
aws sqs send-message --region "$AWS_REGION" --queue-url "$QUEUE_URL" --message-body "$BODY" \
  --query MessageId --output text
