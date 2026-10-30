#!/usr/bin/env bash
# Part 4 on the AWS Free plan (Kinesis/Firehose need the Paid plan, see up-kinesis.sh):
#   producer -> SQS queue -> Lambda (60 s batches) -> S3 stream/ (-> Athena) + SNS e-mail alert
#   BUCKET=lab8-payments-123456789012 EMAIL=you@example.com bash lab8/cloud/up.sh
# Tear down with: bash lab8/cloud/down.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1            # Git Bash on Windows: do not rewrite "/aws/..." arguments
cd "$(dirname "$0")"
REGION=${REGION:-us-east-1}
: "${BUCKET:?set BUCKET (the bucket from Part 2)}"
: "${EMAIL:?set EMAIL (alerts are sent there; confirm the subscription e-mail)}"
PY=${PYTHON:-python}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
QUEUE=lab8-payments
LAMBDA=lab8-stream-processor
TOPIC=lab8-failure-alerts
export AWS_DEFAULT_REGION=$REGION

retry() {  # IAM roles take a few seconds to become usable by other services
  for i in 1 2 3 4 5 6; do "$@" && return 0; echo "  (retry $i in 10 s)"; sleep 10; done; return 1
}

echo "1/4 SQS queue (the stream; visibility timeout > Lambda timeout)"
QUEUE_URL=$(aws sqs create-queue --queue-name $QUEUE \
  --attributes VisibilityTimeout=180,MessageRetentionPeriod=86400 --query QueueUrl --output text)
QUEUE_ARN=arn:aws:sqs:$REGION:$ACCOUNT:$QUEUE

echo "2/4 SNS topic + e-mail subscription"
TOPIC_ARN=$(aws sns create-topic --name $TOPIC --query TopicArn --output text)
if ! aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query 'Subscriptions[].Endpoint' --output text | grep -q "$EMAIL"; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" >/dev/null
  echo "   -> open the e-mail from AWS Notifications and click Confirm subscription"
fi

echo "3/4 IAM role for the Lambda: read the queue, write stream/ in S3, publish the alert"
aws iam get-role --role-name lab8-stream-lambda >/dev/null 2>&1 \
  || aws iam create-role --role-name lab8-stream-lambda --assume-role-policy-document \
     '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam attach-role-policy --role-name lab8-stream-lambda \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole
aws iam put-role-policy --role-name lab8-stream-lambda --policy-name archive-and-alert --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/stream/*\"},
   {\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$TOPIC_ARN\"}]}"

echo "4/4 Lambda + event source mapping (batches of up to 60 s / 10 000 messages)"
"$PY" -c "import zipfile; z=zipfile.ZipFile('stream_lambda.zip','w'); z.write('stream_lambda.py'); z.close()"
if aws lambda get-function --function-name $LAMBDA >/dev/null 2>&1; then
  aws lambda update-function-code --function-name $LAMBDA --zip-file fileb://stream_lambda.zip >/dev/null
else
  retry aws lambda create-function --function-name $LAMBDA --runtime python3.12 \
    --handler stream_lambda.handler --zip-file fileb://stream_lambda.zip --timeout 60 --memory-size 512 \
    --role "arn:aws:iam::$ACCOUNT:role/lab8-stream-lambda" \
    --environment "Variables={BUCKET=$BUCKET,TOPIC_ARN=$TOPIC_ARN,THRESHOLD=0.10,MIN_COUNT=10}" >/dev/null
fi
rm -f stream_lambda.zip
if [ -z "$(aws lambda list-event-source-mappings --function-name $LAMBDA --query 'EventSourceMappings[0].UUID' --output text | grep -v None)" ]; then
  retry aws lambda create-event-source-mapping --function-name $LAMBDA --event-source-arn "$QUEUE_ARN" \
    --batch-size 10000 --maximum-batching-window-in-seconds 60 >/dev/null
fi
echo "Ready: queue $QUEUE_URL"
