# AWS setup (one time) and deploys

Run from **Git Bash** in the repository root, after `aws configure` (region `eu-central-1`).
Each script is safe to re-run; IDs it creates are remembered in `infra/aws/.state` (git-ignored).

| Script | Creates | Time |
|---|---|---|
| `01-network.sh` | default VPC lookup, security groups ALB → ECS → RDS | 1 min |
| `02-database.sh` | RDS PostgreSQL 17 `db.t4g.micro` (private), `DATABASE_URL` in SSM | 10–15 min |
| `03-image.sh` | ECR repository, first backend image `:<commit sha>` | 3–5 min |
| `04-ecs.sh` | execution role, task definition, cluster, ALB + target group, Fargate service | 5–8 min |
| `05-frontend.sh` | private S3 bucket, CloudFront (S3 + `/api/*` → ALB), first frontend deploy | 10–20 min |
| `06-oidc.sh` | GitHub OIDC provider + deploy role (main branch of this repo only) | 1 min |
| `teardown.sh` | deletes all of the above | 5 min |

After that, every push to `main` deploys through `.github/workflows/ci.yml`, which runs the same
targets you can run by hand: `make deploy-backend`, `make deploy-frontend`,
`make rollback-backend TAG=<sha>`.

```
browser ──HTTPS──▶ CloudFront ──┬─ /*      ──OAC──▶ S3 (private)
                                └─ /api/*  ──HTTP─▶ ALB :80 ─▶ ECS Fargate task :8000 ─▶ RDS :5432
GitHub Actions ──OIDC──▶ IAM role spry-github-deploy ──▶ ECR push · ECS update · S3 sync · CF invalidation
```
