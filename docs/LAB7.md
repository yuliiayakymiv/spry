# Lab 7 — Infrastructure as Code: CloudFormation → Terraform

The three CloudFormation templates of Labs 4–6 are Terraform now (`infra/*.tf`), with the state
and the applies in HCP Terraform. Nothing in AWS was re-created that holds data: the stacks were
deleted with `Retain` and every resource was imported. Decision record:
[ADR 0007](adr/0007-terraform.md). File map: [infra/README.md](../infra/README.md).

## What is where

| Was (CloudFormation) | Now (Terraform) |
|---|---|
| `infra/auth.yml`, stack `spry-auth` | `infra/auth.tf` (+ `infra/branding/*` read directly) |
| `infra/reports.yml`, stack `spry-reports` | `infra/reports.tf` (+ `infra/lambda/report_mailer/index.py`) |
| `infra/ai.yml`, stack `spry-ai` | `infra/ai.tf` |
| stack parameters | `infra/variables.tf`, `infra/terraform.tfvars`, secret in the workspace |
| stack outputs read by scripts / CI | `infra/outputs.tf`, published to SSM `/spry/infra/*` by `infra/publish.tf` |
| `make deploy-auth/-reports/-ai` (laptop) | PR → plan → merge → apply in HCP Terraform |
| `09-reports.sh`, `10-ai.sh`, `branding/render.py` | deleted |
| image refresh inside `10-ai.sh` | `make lambda-images` |

## Run sheet (once)

Prerequisites: Terraform ≥ 1.10, `terraform login`, the bootstrap role from Part 1 Step 7
(`~/tf-bootstrap`, output `role_arn`), Git Bash in the repo root with `aws configure` done.

1. **HCP Terraform workspace.** Organization `ooad-yuliiayakymiv` (if yours is named differently,
   change `infra/versions.tf`), workspace `spry-dev`, *CLI-driven* for now, Remote execution.
   Variables: see [infra/README.md](../infra/README.md#workspace-settings-hcp-terraform--spry-dev--variables)
   (`TFC_AWS_PROVIDER_AUTH`, `TFC_AWS_RUN_ROLE_ARN`, sensitive `google_client_secret`).
2. **Retain + real IDs:** `bash infra/migrate/1-retain-and-collect.sh`.
   Updates the three stacks with `DeletionPolicy: Retain` (same parameters), checks AWS stored it,
   then writes `infra/terraform.tfvars` and `infra/imports.tf` from the live resources.
3. **Check before deleting:** `cd infra && terraform init && terraform plan`. Expected:
   `35 to import` (36 with a sender domain), **9 to add** (3 Lambda permissions, 5 SSM parameters,
   1 deploy-role policy), a few `~` (see below), **0 to destroy**. While the stacks still exist this
   is only a preview; do not apply yet.
4. **Delete the stacks, keep the resources:** `bash infra/migrate/2-delete-stacks.sh`
   (refuses unless every resource is `Retain`; afterwards checks the pool, the bucket and the parser).
5. **Plan until it says nothing unexpected:** `terraform plan`. Every `~` is a difference
   between the HCL and the real resource → fix the **HCL**, not the resource. Any `-/+` or
   `forces replacement` → stop. Expected `~` that are fine to apply:
   - `aws_lambda_function.report_mailer`: new code hash (same code, now zipped by Terraform);
   - `tags` adding `PROJECT_NAME` where CloudFormation had not propagated it;
   - the lifecycle rule's `prefix` moving into `filter { prefix }`.
   If unsure about one resource: `terraform plan -generate-config-out=generated.tf` and compare.
6. **Apply:** `terraform apply` (a CLI-driven remote run; this is the only apply not started by a merge).
7. **`terraform plan` → `No changes. Your infrastructure matches the configuration.`**
   Save the output → **submission item 3**.
8. **Tidy up:** `bash infra/migrate/3-after-apply.sh` (old CloudFormation permission statements,
   old deploy-role policies, deletes `imports.tf`). Plan again: still `No changes`.
9. **Commit + PR** (templates already removed in this branch). Merge.
10. **Connect the workspace to GitHub:** Settings → Version Control → this repo, branch `main`,
    working directory `infra`, auto-apply on.
11. **Prove the road (submission item 2):** branch, add `ManagedBy = "terraform"` to `default_tags`
    in `infra/versions.tf`, PR → read the plan in the check (`~ tags` only) → merge → screenshot
    *Apply finished* in HCP Terraform.
12. **Submission item 1:** link to the merged PR / commit.

### Re-created instead of imported (and why it was safe)

| Resource | Why re-created | Why safe |
|---|---|---|
| `aws_lambda_permission.mailer_s3` | CloudFormation statement id was random | a permission holds no data; new id added before the old one is removed |
| `aws_lambda_permission.parser_url`, `.parser_invoke` | same | same; the function URL itself (and so `VITE_PARSER_URL`) was imported, unchanged |
| `aws_ssm_parameter.published[*]`, `aws_iam_role_policy.deploy_reads_infra` | new in Lab 7 | replace stack outputs / the `DescribeStacks` policies |

## Step 4 — two roads

GitHub Actions (`ci.yml`) still deploys the application; HCP Terraform deploys the infrastructure.
When a change needs both (e.g. a new environment variable for the parser Lambda that new code
reads): **infrastructure first, backward compatible** (add the variable; old code ignores it),
merge, apply; **then** the application change that uses it (`make lambda-images`). Removing works
the other way round: code stops using it first, then infra removes it. Same expand/contract rule
as database migrations.

## Step 5 — drift

Changed the parser timeout to 45 s in the console → `terraform plan` (New run → Plan only) shows
`~ timeout = 45 -> 30` on `aws_lambda_function.agenda_parser` → applied, back to 30.

If that had been a real 23:00 fix, the next apply would silently undo it. The fix must end up in
the code: either make it through a PR in the first place (an emergency PR is minutes), or, if it
had to be clicked, open the PR with the same value *before* the next apply (the plan then shows
no change). The console change is a hotfix, the PR is the record.

## Step 7 — answers

1. **Imported vs re-created:** 35 imported (5 auth, 23 reports, 7 ai); 3 Lambda permissions
   re-created, plus 6 new resources from `publish.tf`. Why safe: table above.
2. **Attribute that forces replacement:** `aws_s3_bucket.reports.bucket` (the name; it comes from
   `project_name`) and `aws_cognito_user_pool.main.username_attributes` / `schema`. Replacing the
   bucket = every weekly report gone; replacing the pool = every account and password gone and a
   new pool id, so the frontend and the API must be rebuilt and everyone signs up again.
   `prevent_destroy` turns such a plan into an error.
3. **Where the Google client secret is now:** the workspace variable (sensitive, write-only);
   the **Terraform state** in HCP Terraform (plain text); Cognito itself (the IdP config — readable
   by anyone with `cognito-idp:DescribeIdentityProvider`); `.env` on our laptops; Google Cloud
   console. Leak risks: anyone with state read access in the workspace, anyone with that IAM
   permission (the bootstrap role has admin), a laptop `.env`. It is *not* in Git, plans or logs.
4. **Two applies at the same time:** HCP Terraform locks the state for a run; the second run
   queues (or `terraform apply` fails with "state locked") and then plans against the new state.
   With `terraform.tfstate` in Git: each laptop has its own copy, both apply, both "create" the
   same resources (duplicates or name conflicts), and the merge conflict is in a JSON file that
   maps names to real IDs — someone's resources become unmanaged. Plus the secrets in it are in Git.
5. **Narrower trust for one workspace:**
   ```
   "app.terraform.io:sub": "organization:ooad-yuliiayakymiv:project:*:workspace:spry-dev:run_phase:*"
   ```
   (and `StringEquals` on `aud`). What it really needs instead of AdministratorAccess:
   `AmazonCognitoPowerUser`, `AWSLambda_FullAccess`, `AmazonSQSFullAccess`, `AmazonS3FullAccess`
   (or a policy limited to `arn:aws:s3:::spry-reports-*`), plus `iam:*Role*`/`iam:*RolePolicy*`/
   `iam:PassRole` on `arn:aws:iam::*:role/spry-*`, `scheduler:*`, `ses:*EmailIdentity*`,
   `logs:*` on `/aws/lambda/spry-*`, `budgets:*`, `ssm:*` on `parameter/spry/*`,
   `ec2:*VpcEndpoint*` + `ec2:Describe*`, `ecs:Describe*`.
6. **Claude Code: "add a staging environment".** Should produce a PR: either a second workspace
   `spry-stage` with `stage.tfvars` (different `project_name`/prefix, smaller budget, no
   `prevent_destroy` needed) or a module refactor (`modules/spry` + `envs/dev`, `envs/stage`),
   plus the plan output and a note on what it costs. Not allowed on its own: `terraform apply`,
   creating workspaces/variables with credentials, editing the trust policy or the bootstrap
   role, `terraform state rm`/`import` against dev, and anything that changes `spry-dev`'s plan
   beyond "No changes".

## Class discussion — short answers

**The need**
- *Artur's Lambda found 6 months later.* (a) import it into Terraform (write HCL, `import` block,
  plan to zero) — if it is used; (b) delete it — if nothing uses it (check its logs/invocations
  first); (c) leave it and document it as unmanaged — never. I choose (a) if it has invocations in
  the last weeks, otherwise (b) after a week with it disabled.
- *23:00 security-group fix in the console.* The next apply reverts it (drift). Process: hotfix
  allowed, but a PR with the same change within the same night/morning; the plan before any apply
  must show "No changes" for that resource. Better: emergency PR + fast-track review.

**State**
- *CloudFormation keeps the state / Terraform makes us.* CFN: nothing to lose or secure, automatic
  rollback. Terraform: one state across clouds and accounts, full control (import, move, inspect).
- *State file deleted:* the cloud resources are NOT lost; the mapping "address → real ID" is. The
  next plan wants to create everything again. Recovery: HCP Terraform keeps every state version
  (roll back to the previous one); otherwise re-import everything with `import` blocks.
- *State in Git:* (1) it contains secrets in plain text (client secret, DATABASE_URL); (2) no
  locking — two people work from two copies and diverge; also merge conflicts in a JSON nobody can
  resolve by hand.

**Workflow**
- *Harmless diff, dangerous plan:* changing `project_name = "spry"` → `"spry-app"` is one line;
  the plan replaces the bucket, the user pool, every role and function (`-/+`). Or a new
  `username_attributes` on the pool: one word, `forces replacement`.
- *`-target`:* an apply fails halfway because of one broken resource and something else must go
  out now — apply only that resource. *`terraform state rm`:* a resource must leave Terraform's
  control without being deleted (handed to another workspace, or a provider bug blocks every plan).
- *Agent writes, human reviews, HCP applies:* automate further — writing the HCL, plan on every PR,
  policy checks (no `-/+` on protected resources, cost estimate). Never automate — the approval of
  a plan that destroys or replaces something, and giving the agent apply rights or admin keys.

**Architecture**
- *White-label `prod · rozetka`:* the HCL becomes a module (`modules/spry`); stays the same:
  the resources and their shape. Changes: a new workspace `spry-prod-rozetka` with its own state,
  its own `rozetka.tfvars` (`brand`, `domain`, logo files, `project_name = "rozetka"`), a provider
  pointed at their AWS account (their own OIDC role trusting our HCP organization), their own
  Google OAuth client. One PR to the module reaches every environment.
- *Run fails halfway through 10 resources:* the world has the ones that succeeded (e.g. 6); the
  state records exactly those 6 (Terraform writes state as it goes); the code still describes 10.
  Fix the cause in the code, plan (shows 4 to add) and apply again. No manual cleanup unless the
  plan shows something unexpected.
