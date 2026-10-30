#!/usr/bin/env bash
# Part 2, Way B: a Glue Crawler over the same payments/ prefix. It writes its own table
# (crawled_payments) into the lab8 database next to the hand-written payment_events,
# then this script prints both schemas side by side.
#   BUCKET=lab8-payments-123456789012 bash lab8/athena/crawler.sh
set -euo pipefail
REGION=us-east-1
: "${BUCKET:?set BUCKET to your bucket name}"
ROLE=lab8-glue-crawler
CRAWLER=lab8-payments

if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
  aws iam put-role-policy --role-name "$ROLE" --policy-name read-payments --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
      \"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/payments/*\"]}]}"
  echo "waiting for the new role to propagate..."; sleep 15
fi
ROLE_ARN=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)

if ! aws glue get-crawler --name "$CRAWLER" --region "$REGION" >/dev/null 2>&1; then
  aws glue create-crawler --region "$REGION" --name "$CRAWLER" --role "$ROLE_ARN" \
    --database-name lab8 --table-prefix crawled_ \
    --targets "{\"S3Targets\":[{\"Path\":\"s3://$BUCKET/payments/\"}]}"
fi

aws glue start-crawler --name "$CRAWLER" --region "$REGION"
echo -n "crawling"
while [ "$(aws glue get-crawler --name "$CRAWLER" --region "$REGION" --query Crawler.State --output text)" != READY ]; do
  echo -n "."; sleep 10
done
echo
aws glue get-crawler-metrics --crawler-name-list "$CRAWLER" --region "$REGION" \
  --query 'CrawlerMetricsList[0].[TablesCreated,TablesUpdated,LastRuntimeSeconds]' --output text

for T in crawled_payments payment_events; do
  echo; echo "== $T =="
  aws glue get-table --database-name lab8 --name "$T" --region "$REGION" \
    --query 'Table.{columns: StorageDescriptor.Columns[].[Name, Type], partitions: PartitionKeys[].[Name, Type], serde: StorageDescriptor.SerdeInfo.SerializationLibrary}' \
    --output yaml
done
echo
echo "Partitions the crawler registered:"
aws glue get-partitions --database-name lab8 --table-name crawled_payments --region "$REGION" \
  --query 'length(Partitions)'
