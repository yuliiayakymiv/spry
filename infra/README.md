# infra/ — Terraform for Spry (Lab 7)

| File | What | Was |
|---|---|---|
| `versions.tf` | HCP Terraform workspace `spry-dev`, providers, default tag `PROJECT_NAME` | — |
| `variables.tf` / `terraform.tfvars` | inputs; tfvars holds non-secret values only | stack parameters |
| `data.tf` | reads the Lab 2 stack (default VPC, `spry-ecs` SG, `/spry/DATABASE_URL`, the API image) | `.state` + CLI lookups in 09/10 scripts |
| `auth.tf` | Cognito user pool, Google IdP, app client, domain, managed-login branding | `auth.yml` (stack `spry-auth`) |
| `reports.tf` | reports bucket, S3 endpoint, queue + DLQ, schedule, builder + mailer Lambdas, SES | `reports.yml` (stack `spry-reports`) |
| `ai.tf` | agenda-parser Lambda + function URL, budget | `ai.yml` (stack `spry-ai`) |
| `publish.tf` | outputs → SSM `/spry/infra/*` for the deploy scripts and CI | stack outputs |
| `outputs.tf` | `terraform output` | stack outputs |
| `branding/` | sign-in page look, read directly by `auth.tf` (`render.py` is gone) | pasted into `auth.yml` |
| `lambda/report_mailer/` | mailer source, zipped by `archive_file` | inline `ZipFile` |
| `bootstrap/` | one-time: OIDC provider + role for HCP Terraform (local state, run once) | — |
| `migrate/` | the one-time CloudFormation → Terraform migration (kept as a record) | — |
| `aws/` | Lab 2 setup scripts and deploy scripts (not Terraform) | — |

## How a change gets to AWS

```
edit *.tf → pull request → HCP Terraform speculative plan (check on the PR) → review the PLAN
         → merge to main → HCP Terraform plan + apply (workspace spry-dev, OIDC → role in AWS)
```

Locally: `terraform login` once, then `make infra-init`, `make infra-plan` (runs in HCP
Terraform, changes nothing). There is no apply target on purpose.

## Workspace settings (HCP Terraform → spry-dev → Variables)

| Key | Category | Value |
|---|---|---|
| `TFC_AWS_PROVIDER_AUTH` | env | `true` |
| `TFC_AWS_RUN_ROLE_ARN` | env | `role_arn` output of the bootstrap folder |
| `google_client_secret` | terraform, **sensitive** | the Google OAuth client secret |

Settings → Version Control: this repository, branch `main`, working directory `infra`.

## Things to know

- **Images.** `report-builder` and `agenda-parser` run the backend image. Terraform ignores
  `image_uri`; after a backend deploy that changes `app/reports` or `app/ai`, run
  `make lambda-images`.
- **Protected.** `aws_cognito_user_pool.main` and `aws_s3_bucket.reports` have
  `prevent_destroy`: a plan that would replace them fails. Remove the line in a PR only if you
  really mean it (teardown).
- **Drift.** A change made in the console shows up as `~` in the next plan and is reverted by
  the next apply. Make the fix in a PR instead (see docs/LAB7.md, Step 5).
