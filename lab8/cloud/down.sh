#!/usr/bin/env bash
# Part 4 teardown: everything that costs money per hour goes away.
# The data Firehose wrote (s3://$BUCKET/stream/) and the Athena table stay for the screenshot;
# delete the whole bucket at the end of the lab with: aws s3 rb s3://$BUCKET --force
set -uo pipefail
export MSYS_NO_PATHCONV=1
export AWS_DEFAULT_REGION=${REGION:-us-east-1}
LAMBDA=lab8-failure-alert

for uuid in $(aws lambda list-event-source-mappings --function-name $LAMBDA --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
  aws lambda delete-event-source-mapping --uuid "$uuid" >/dev/null && echo "deleted event source mapping $uuid"
done
aws lambda delete-function --function-name $LAMBDA && echo "deleted Lambda $LAMBDA"
aws logs delete-log-group --log-group-name /aws/lambda/$LAMBDA 2>/dev/null && echo "deleted its log group"
aws firehose delete-delivery-stream --delivery-stream-name lab8-payments-to-s3 && echo "deleted Firehose stream"
aws kinesis delete-stream --stream-name lab8-payments --enforce-consumer-deletion && echo "deleted Kinesis stream"
TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':lab8-failure-alerts')].TopicArn" --output text)
[ -n "$TOPIC_ARN" ] && aws sns delete-topic --topic-arn "$TOPIC_ARN" && echo "deleted SNS topic"
for role in lab8-firehose lab8-alert-lambda; do
  for p in $(aws iam list-role-policies --role-name $role --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name $role --policy-name "$p"; done
  for a in $(aws iam list-attached-role-policies --role-name $role --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name $role --policy-arn "$a"; done
  aws iam delete-role --role-name $role 2>/dev/null && echo "deleted role $role"
done
echo
echo "Check that nothing is left:"
aws kinesis list-streams --query StreamNames --output text
aws firehose list-delivery-streams --query DeliveryStreamNames --output text
