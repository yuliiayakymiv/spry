# Spry on Google Cloud (`gcp/`)

The core of Spry — frontend, API, database — on Google Cloud, next to the AWS stack in `infra/`.
Decisions: [ADR 0008](../docs/adr/0008-google-cloud.md). Lab write-up: [docs/LAB9.md](../docs/LAB9.md).

| File | What |
|---|---|
| `versions.tf` | `google` / `google-beta` providers impersonating `terraform@`; state in its own GCS bucket (separate from the AWS state) |
| `apis.tf` | the APIs this configuration needs, enabled by Terraform |
| `database.tf` | Cloud SQL PostgreSQL 17 `db-f1-micro`, 10 GB SSD; database + user; password → Secret Manager |
| `run.tf` | Artifact Registry, service account `spry-api@`, Cloud Run service `spry-api` (min 0) |
| `hosting.tf` | Firebase project + Hosting site `<project>.web.app` |
| `bootstrap/` | run once by a person: `terraform@` service account (least privilege), who may impersonate it, the state bucket |
| `deploy.sh` | the application road: image → Cloud Run, static build → Firebase Hosting |
| `../frontend/firebase.json` | Hosting config: `/api/**` → Cloud Run, everything else → `index.html` |

## What runs where

| Google Cloud (europe-west1) | Still on AWS (eu-central-1) |
|---|---|
| site (Firebase Hosting), API (Cloud Run), database (Cloud SQL), secrets, logs | sign-in (Cognito + Google; the API verifies Cognito tokens), weekly report (Scheduler → SQS → Lambda → SES), agenda parser (Lambda + Bedrock) |

## Deploy

No service account keys anywhere: you run Terraform with your own `gcloud` login, and the providers
impersonate `terraform@` (short-lived tokens, only its roles). State: the versioned bucket
`gs://spry-yuliia-2026-tfstate/gcp/`, separate from the AWS state in HCP Terraform (`spry-dev`).

1. **Once — bootstrap** (Cloud Shell, as yourself, local state):
   ```sh
   cd gcp/bootstrap && terraform init
   terraform apply -var project_id=spry-yuliia-2026 -var admin=user:$(gcloud config get account)
   ```
2. **Infrastructure:** `cd gcp && terraform init && terraform plan && terraform apply`
   (values in `gcp/terraform.tfvars`; nothing secret there).
3. **Application:** in Cloud Shell, repo root:
   ```sh
   PROJECT_ID=spry-yuliia-2026 COGNITO_AUTHORITY=... COGNITO_CLIENT_ID=... COGNITO_DOMAIN=... bash gcp/deploy.sh
   ```
   Migrations run at container start (`alembic upgrade head`) against the empty database; no data
   was copied from AWS.
4. Open `https://spry-yuliia-2026.web.app` in a private window → sign in → the meetings list (reads
   Cloud SQL). `curl https://spry-yuliia-2026.web.app/api/health` → `{"status":"ok"}`.

## Stop the database (it does not pause on its own)

- **Stop** (storage still bills, $1.70/month): `terraform apply -var db_activation_policy=NEVER`, or `gcloud sql instances patch spry-db --activation-policy=NEVER`.
  Start again with `ALWAYS` (~1 min). While stopped, every API call that reads the DB fails.
- **Delete everything:** `terraform destroy` here. Then `terraform destroy` in `bootstrap/` and, if you like, delete
  the project. Check Billing → Reports a day later.
