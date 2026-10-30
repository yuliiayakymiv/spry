#!/usr/bin/env bash
# Part 4: Kinesis Data Stream -> Firehose -> S3 (-> Athena), and Kinesis -> Lambda -> SNS e-mail.
#   BUCKET=lab8-payments-123456789012 EMAIL=you@example.com bash lab8/cloud/up.sh
# Costs money while it exists (mostly the shard hour). Tear down with: bash lab8/cloud/down.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1            # Git Bash on Windows: do not rewrite "/aws/..." arguments
cd "$(dirname "$0")"
REGION=${REGION:-us-east-1}
: "${BUCKET:?set BUCKET (the bucket from Part 2)}"
: "${EMAIL:?set EMAIL (alerts are sent there; confirm the subscription e-mail)}"
PY=${PYTHON:-python}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
STREAM=lab8-payments
FIREHOSE=lab8-payments-to-s3
LAMBDA=lab8-failure-alert
TOPIC=lab8-failure-alerts
export AWS_DEFAULT_REGION=$REGION

retry() {  # IAM roles take a few seconds to become usable by other services
  for i in 1 2 3 4 5 6; do "$@" && return 0; echo "  (retry $i in 10 s)"; sleep 10; done; return 1
}

echo "1/5 Kinesis data stream (provisioned, 1 shard = 1 MB/s or 1000 records/s in)"
aws kinesis describe-stream-summary --stream-name $STREAM >/dev/null 2>&1 \
  || aws kinesis create-stream --stream-name $STREAM --shard-count 1 \
       --stream-mode-details StreamMode=PROVISIONED
aws kinesis wait stream-exists --stream-name $STREAM
STREAM_ARN=arn:aws:kinesis:$REGION:$ACCOUNT:stream/$STREAM

echo "2/5 IAM roles"
trust() { echo "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$1\"},\"Action\":\"sts:AssumeRole\"}]}"; }
aws iam get-role --role-name lab8-firehose >/dev/null 2>&1 \
  || aws iam create-role --role-name lab8-firehose --assume-role-policy-document "$(trust firehose.amazonaws.com)" >/dev/null
aws iam put-role-policy --role-name lab8-firehose --policy-name stream-to-s3 --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
   {\"Effect\":\"Allow\",\"Action\":[\"kinesis:DescribeStream\",\"kinesis:GetShardIterator\",\"kinesis:GetRecords\",\"kinesis:ListShards\"],\"Resource\":\"$STREAM_ARN\"},
   {\"Effect\":\"Allow\",\"Action\":[\"s3:AbortMultipartUpload\",\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\",\"s3:ListBucketMultipartUploads\",\"s3:PutObject\"],
    \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"]}]}"
aws iam get-role --role-name lab8-alert-lambda >/dev/null 2>&1 \
  || aws iam create-role --role-name lab8-alert-lambda --assume-role-policy-document "$(trust lambda.amazonaws.com)" >/dev/null
aws iam attach-role-policy --role-name lab8-alert-lambda \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaKinesisExecutionRole

echo "3/5 SNS topic + e-mail subscription"
TOPIC_ARN=$(aws sns create-topic --name $TOPIC --query TopicArn --output text)
aws iam put-role-policy --role-name lab8-alert-lambda --policy-name publish-alerts --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"$TOPIC_ARN\"}]}"
if ! aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query 'Subscriptions[].Endpoint' --output text | grep -q "$EMAIL"; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" >/dev/null
  echo "   -> open the e-mail from AWS Notifications and click Confirm subscription"
fi

echo "4/5 Firehose: stream -> s3://$BUCKET/stream/dt=<arrival date>/ (gzip JSON, every 60 s)"
if ! aws firehose describe-delivery-stream --delivery-stream-name $FIREHOSE >/dev/null 2>&1; then
  S3CONF=$(printf '{"RoleARN":"%s","BucketARN":"arn:aws:s3:::%s","Prefix":"stream/dt=!{timestamp:yyyy-MM-dd}/","ErrorOutputPrefix":"stream-errors/!{firehose:error-output-type}/dt=!{timestamp:yyyy-MM-dd}/","BufferingHints":{"IntervalInSeconds":60,"SizeInMBs":5},"CompressionFormat":"GZIP"}' \
    "arn:aws:iam::$ACCOUNT:role/lab8-firehose" "$BUCKET")
  retry aws firehose create-delivery-stream --delivery-stream-name $FIREHOSE \
    --delivery-stream-type KinesisStreamAsSource \
    --kinesis-stream-source-configuration "KinesisStreamARN=$STREAM_ARN,RoleARN=arn:aws:iam::$ACCOUNT:role/lab8-firehose" \
    --extended-s3-destination-configuration "$S3CONF" >/dev/null
fi

echo "5/5 Lambda with a 60-second tumbling window on the stream"
"$PY" -c "import zipfile; z=zipfile.ZipFile('alert_lambda.zip','w'); z.write('alert_lambda.py'); z.close()"
if aws lambda get-function --function-name $LAMBDA >/dev/null 2>&1; then
  aws lambda update-function-code --function-name $LAMBDA --zip-file fileb://alert_lambda.zip >/dev/null
else
  retry aws lambda create-function --function-name $LAMBDA --runtime python3.12 \
    --handler alert_lambda.handler --zip-file fileb://alert_lambda.zip --timeout 60 --memory-size 256 \
    --role "arn:aws:iam::$ACCOUNT:role/lab8-alert-lambda" \
    --environment "Variables={TOPIC_ARN=$TOPIC_ARN,THRESHOLD=0.10,MIN_COUNT=10}" >/dev/null
fi
rm -f alert_lambda.zip
if [ -z "$(aws lambda list-event-source-mappings --function-name $LAMBDA --query 'EventSourceMappings[0].UUID' --output text | grep -v None)" ]; then
  retry aws lambda create-event-source-mapping --function-name $LAMBDA --event-source-arn "$STREAM_ARN" \
    --starting-position LATEST --batch-size 500 --maximum-batching-window-in-seconds 5 \
    --tumbling-window-in-seconds 60 >/dev/null
fi

cat <<NEXT

Ready. Next:
  python lab8/producer.py lab8/data/events.jsonl --sink kinesis --stream $STREAM --start 08:00 --max-events 20000
  python lab8/producer.py lab8/data/events.jsonl --sink kinesis --stream $STREAM --start 08:00 --max-events 6000 --fail-share 0.3
  Lambda output:  aws logs tail /aws/lambda/$LAMBDA --follow
  ~1-2 min later: python lab8/athena/run_athena.py --bucket $BUCKET --dir cloud/sql
  When done:      bash lab8/cloud/down.sh
NEXT
