#!/usr/bin/env bash
# Part 2, step 0: your own bucket in us-east-1 and a server-side copy of the dataset into it.
# Copying inside one region is free. Run from Git Bash after `aws configure`.
#   bash lab8/athena/setup.sh            -> prints the bucket name to pass to run_athena.py
set -euo pipefail
REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=${BUCKET:-lab8-payments-$ACCOUNT}

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  # us-east-1 is the one region where create-bucket takes no LocationConstraint.
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

# S3 -> S3 copy: the bytes never pass through your laptop.
# --copy-props none: files over 8 MB are copied in parts, and by default the CLI then also
# copies their tags (GetObjectTagging), which the course bucket does not allow.
aws s3 sync s3://ucu-ooad-lab8-payments/payments/ "s3://$BUCKET/payments/" --region "$REGION" --copy-props none

echo
aws s3 ls "s3://$BUCKET/payments/" --recursive --summarize --human-readable | tail -2
echo "BUCKET=$BUCKET"
