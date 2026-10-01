#!/usr/bin/env bash
# Private S3 bucket + CloudFront. CloudFront serves the app from S3 and forwards /api/* to
# the ALB, so the browser talks HTTPS to one address and needs no CORS.
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")"
: "${ALB_DNS:?run 04-ecs.sh first}"
BUCKET="spry-frontend-$ACCOUNT_ID"

step "S3 bucket $BUCKET (private — Block Public Access stays on)"
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration "LocationConstraint=$AWS_REGION" --query Location --output text
fi
save S3_BUCKET "$BUCKET"

step "Origin Access Control (CloudFront signs its requests to S3)"
OAC_ID=$(t aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='spry-frontend'].Id | [0]" --output text)
if [[ "$OAC_ID" == "None" || -z "$OAC_ID" ]]; then
  OAC_ID=$(t aws cloudfront create-origin-access-control --origin-access-control-config \
    "Name=spry-frontend,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query OriginAccessControl.Id --output text)
fi

if [[ -z "${CF_DIST_ID:-}" ]]; then
  step "CloudFront distribution"
  # Managed policy IDs (same in every account):
  #   658327ea-… CachingOptimized · 4135ea2d-… CachingDisabled · b689b0a8-… AllViewerExceptHostHeader
  cat > cf.rendered.json <<JSON
{
  "CallerReference": "spry-$(date +%s)",
  "Comment": "Spry frontend (S3) + /api/* to the ALB",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "PriceClass": "PriceClass_100",
  "HttpVersion": "http2and3",
  "Origins": { "Quantity": 2, "Items": [
    { "Id": "s3-frontend",
      "DomainName": "$BUCKET.s3.$AWS_REGION.amazonaws.com",
      "S3OriginConfig": { "OriginAccessIdentity": "" },
      "OriginAccessControlId": "$OAC_ID" },
    { "Id": "alb-api",
      "DomainName": "$ALB_DNS",
      "CustomOriginConfig": { "HTTPPort": 80, "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only", "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] } } }
  ]},
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-frontend",
    "ViewerProtocolPolicy": "redirect-to-https",
    "Compress": true,
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] } }
  },
  "CacheBehaviors": { "Quantity": 1, "Items": [{
    "PathPattern": "/api/*",
    "TargetOriginId": "alb-api",
    "ViewerProtocolPolicy": "redirect-to-https",
    "Compress": true,
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
    "AllowedMethods": { "Quantity": 7, "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] } }
  }]}
}
JSON
  read -r CF_DIST_ID CF_DOMAIN < <(t aws cloudfront create-distribution \
    --distribution-config file://cf.rendered.json \
    --query '[Distribution.Id, Distribution.DomainName]' --output text)
  rm -f cf.rendered.json
  save CF_DIST_ID "$CF_DIST_ID"; save CF_DOMAIN "$CF_DOMAIN"
else
  echo "   (distribution $CF_DIST_ID already exists)"
fi

step "Bucket policy: only this distribution may read the bucket"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"cloudfront.amazonaws.com\"},\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/*\",\"Condition\":{\"StringEquals\":{\"AWS:SourceArn\":\"arn:aws:cloudfront::$ACCOUNT_ID:distribution/$CF_DIST_ID\"}}}]}"

step "First frontend deploy"
cd ../..
S3_BUCKET="$BUCKET" CLOUDFRONT_DISTRIBUTION_ID="$CF_DIST_ID" bash infra/aws/deploy-frontend.sh

step "Waiting for CloudFront to finish deploying (5–15 min)…"
aws cloudfront wait distribution-deployed --id "$CF_DIST_ID"
echo
echo "App:  https://$CF_DOMAIN"
echo "API:  https://$CF_DOMAIN/api/docs   (and http://$ALB_DNS/api/docs directly)"
echo "Done. Next: bash infra/aws/06-oidc.sh"
