#!/usr/bin/env bash
# One command for the whole Lab 2 AWS setup (no domain yet):
#   commit + push → network → database → image → ECS + ALB → S3 + CloudFront → OIDC
# Re-run it after fixing an error: every step skips what already exists.
set -euo pipefail
cd "$(dirname "$0")/../.."
LOG="infra/aws/setup.log"
exec > >(tee -a "$LOG") 2>&1
echo "===== $(date) ====="

if [[ -n "$(git status --porcelain)" ]]; then
  echo "==> Committing local changes"
  git add -A
  git commit -m "AWS setup scripts (VPC/SG, RDS, ECR, ECS+ALB, S3+CloudFront, OIDC) and CD jobs"
fi
echo "==> Pushing to GitHub"
git push

for s in 01-network 02-database 03-image 04-ecs 05-frontend 06-oidc; do
  echo; echo "############ $s ############"
  bash "infra/aws/$s.sh"
done
echo; echo "ALL DONE. Copy the 4 variables printed above into GitHub → Settings → Secrets and variables → Actions → Variables."
