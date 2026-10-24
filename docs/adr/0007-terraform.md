# ADR 0007 — Labs 4–6 infrastructure in Terraform, state and applies in HCP Terraform

- Status: accepted
- Date: 2026-10-24
- Lab: 7 (Infrastructure as Code)

## Context

Labs 4–6 added three CloudFormation templates (`infra/auth.yml`, `infra/reports.yml`,
`infra/ai.yml`), deployed from a laptop by `07-auth.sh`, `09-reports.sh`, `10-ai.sh`. That works,
but:

- **Only part of Spry fits in CloudFormation.** The Google OAuth client, the GitHub repository and
  its settings are outside AWS; a second environment (stage, a white-label prod) would mean
  copying stacks by hand.
- **Changes are invisible until they happen.** `aws cloudformation deploy` from a laptop has no
  review step; change sets were optional and nobody looked at them.
- **Who can change infrastructure = whoever has admin keys on a laptop.**
- The reports bucket holds every weekly report, the user pool every account since Lab 4:
  the migration must not re-create either.

## Decision

1. **Terraform** (HCL, AWS provider `~> 6.70`) describes everything the three templates did, in
   `infra/auth.tf`, `reports.tf`, `ai.tf`, one root module. Names are unchanged.
2. **Existing resources were adopted, not re-created:** stacks updated with
   `DeletionPolicy: Retain`, deleted, resources taken over with `import` blocks
   (`infra/migrate/`). 35 imported; 3 Lambda permissions re-created (CloudFormation had given
   them random statement ids; a permission is stateless). The user pool and the reports bucket
   have `prevent_destroy = true`.
3. **State in HCP Terraform**, workspace `spry-dev` (one workspace = one environment), with
   locking and version history. The workspace is connected to GitHub (working directory
   `infra`): a pull request gets a speculative plan as a check, a merge to `main` plans and
   applies. **No apply from laptops, no apply in the Makefile.**
4. **HCP Terraform reaches AWS with dynamic credentials:** a signed OIDC token per run,
   exchanged for the bootstrap role `hcp-terraform-<org>` (created once with Terraform from a
   laptop). No AWS keys are stored anywhere.
5. **Two roads stay separate.** GitHub Actions deploys the *application* (image to ECR/ECS,
   frontend to S3); HCP Terraform deploys the *infrastructure*. The image the two Lambdas run is
   the application's (`lifecycle.ignore_changes = [image_uri]`, `make lambda-images`).
   The values the application road needs from Terraform (Cognito ids, parser URL, queue URL)
   are published as SSM parameters `/spry/infra/*`, readable by the GitHub deploy role.
6. **The Lab 2 stack stays as it is** (VPC, RDS, ECS, CloudFront, created by `infra/aws/0*.sh`).
   Terraform only reads it through data sources (`infra/data.tf`).

## Alternatives

- **Keep CloudFormation.** AWS keeps the state and rolls back failed changes automatically;
  free. But AWS-only, and the parts of Spry outside AWS (Google OAuth client, GitHub) would stay
  in somebody's memory. Rejected.
- **AWS CDK.** Real programming language, still CloudFormation underneath: same single-cloud
  limit, plus a Node/Python toolchain just for infrastructure. Rejected.
- **OpenTofu.** Same language and the same files (`tofu` instead of `terraform`), open licence
  (MPL) instead of BSL. A good choice; we use Terraform because the course uses HCP Terraform,
  which runs Terraform. Switching later is a binary swap plus a state backend change.
- **State in S3 with a lock file.** Works, but we would have to run the plans ourselves (or in
  GitHub Actions) and secure the bucket; HCP Terraform gives runs, locking, history and the VCS
  workflow on its free tier.

## Consequences

- **Who can change infrastructure:** anyone who can get a pull request merged into `main`.
  The plan is reviewed, not just the HCL diff. Emergency: an admin can still change AWS by hand,
  but the next plan shows it as drift and puts it back, so the fix must also go into a PR.
- **Secrets.** The Google client secret is a *sensitive* variable in the workspace (write-only in
  the UI, `(sensitive value)` in plans). It is still stored in plain text in the Terraform
  **state** and in Cognito; `DATABASE_URL` (read from SSM) is in the state and in the
  report-builder's environment. So the state is a secret: only the workspace's members can read
  it in HCP Terraform; it is never in Git (`.gitignore`).
- **The bootstrap role has AdministratorAccess** and trusts every workspace of the
  organization. Acceptable for the course; next step: trust only
  `organization:<org>:project:*:workspace:spry-dev:run_phase:*` and narrow the policy to Cognito,
  Lambda, S3, SQS, Scheduler, SES, Logs, IAM on `spry-*`, Budgets, SSM `/spry/infra/*`.
- **If HCP Terraform is down:** the running system is unaffected (it is plain AWS). Only
  infrastructure *changes* wait. In a real emergency: switch the workspace to Local execution and
  apply from a laptop with your own credentials, still against the remote state (locked) —
  or wait. Never copy the state to a laptop.
- **No automatic rollback.** A failed apply stops halfway; the state records what was created.
  We fix the code and apply again (or revert the commit and apply).
- **New AWS features** can reach the Terraform provider later than CloudFormation (example:
  the second function-URL permission needs provider 6.70+).
