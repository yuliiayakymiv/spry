#!/usr/bin/env bash
# Ask for a report on demand: puts the same message on the queue that the Monday schedule sends.
# Called by `make report-now WEEK=2026-W39` (empty WEEK = the builder picks last week).
set -euo pipefail
export MSYS_NO_PATHCONV=1 AWS_PAGER=""

: "${AWS_REGION:?}"
REPORTS_STACK="${REPORTS_STACK:-spry-reports}"
WEEK="${WEEK:-}"

if [[ -n "$WEEK" && ! "$WEEK" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
  echo "WEEK must look like 2026-W39, got '$WEEK'" >&2
  exit 1
fi

QUEUE_URL=$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$REPORTS_STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='QueueUrl'].OutputValue" --output text | tr -d '\r')
if [[ -n "$WEEK" ]]; then
  BODY="{\"week\": \"$WEEK\", \"source\": \"make\"}"
else
  BODY='{"week": null, "source": "make"}'
fi

echo "==> $BODY → $QUEUE_URL"
aws sqs send-message --region "$AWS_REGION" --queue-url "$QUEUE_URL" --message-body "$BODY" \
  --query MessageId --output text
