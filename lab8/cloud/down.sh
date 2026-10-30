#!/usr/bin/env bash
# Part 4 teardown (Free-plan version). The files in s3://$BUCKET/stream/ and the Athena table stay
# for the screenshot; at the very end of the lab: aws s3 rb s3://$BUCKET --force
set -uo pipefail
export MSYS_NO_PATHCONV=1
export AWS_DEFAULT_REGION=${REGION:-us-east-1}
LAMBDA=lab8-stream-processor

for uuid in $(aws lambda list-event-source-mappings --function-name $LAMBDA --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
  aws lambda delete-event-source-mapping --uuid "$uuid" >/dev/null && echo "deleted event source mapping"
done
aws lambda delete-function --function-name $LAMBDA 2>/dev/null && echo "deleted Lambda $LAMBDA"
aws logs delete-log-group --log-group-name /aws/lambda/$LAMBDA 2>/dev/null && echo "deleted its log group"
URL=$(aws sqs get-queue-url --queue-name lab8-payments --query QueueUrl --output text 2>/dev/null) \
  && aws sqs delete-queue --queue-url "$URL" && echo "deleted SQS queue"
TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':lab8-failure-alerts')].TopicArn" --output text)
[ -n "$TOPIC_ARN" ] && aws sns delete-topic --topic-arn "$TOPIC_ARN" && echo "deleted SNS topic"
role=lab8-stream-lambda
for p in $(aws iam list-role-policies --role-name $role --query 'PolicyNames' --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name $role --policy-name "$p"; done
for a in $(aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name $role --policy-arn "$a"; done
aws iam delete-role --role-name $role 2>/dev/null && echo "deleted role $role"
