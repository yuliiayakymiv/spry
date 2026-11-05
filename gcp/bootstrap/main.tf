# Run ONCE, by a person, with their own gcloud login and local state (Cloud Shell):
#   cd gcp/bootstrap && terraform init && terraform apply -var project_id=spry-yuliia-2026 -var admin=user:you@gmail.com
# Creates what gcp/ needs before it can run:
#   - the service account `terraform@` with only the roles gcp/ needs (no Owner / Editor);
#   - the right for ONE person to impersonate it (short-lived tokens; no key is ever created);
#   - a versioned Cloud Storage bucket for gcp/'s state.

terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.10"
    }
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "admin" {
  type        = string
  description = "Who may run gcp/ as terraform@, e.g. user:you@gmail.com"
}

provider "google" {
  project = var.project_id
}

resource "google_project_service" "base" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

resource "google_service_account" "terraform" {
  account_id   = "terraform"
  display_name = "Terraform for gcp/ (impersonated, no keys)"
  depends_on   = [google_project_service.base]
}

locals {
  terraform_roles = [
    # the lab's list
    "roles/run.admin",
    "roles/cloudsql.admin",
    "roles/artifactregistry.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/iam.serviceAccountUser",
    # what gcp/ also creates: the API's service account and its role bindings,
    # the Firebase project and Hosting site
    "roles/iam.serviceAccountAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/firebase.admin",
  ]
}

resource "google_project_iam_member" "terraform" {
  for_each = toset(local.terraform_roles)
  project  = var.project_id
  role     = each.value
  member   = google_service_account.terraform.member
}

# Only this person can mint short-lived tokens for terraform@.
resource "google_service_account_iam_member" "admin_impersonates" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = var.admin
}

resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true # lab: let `terraform destroy` here remove it

  versioning {
    enabled = true # every state version kept: a bad apply can be rolled back
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.base]
}

resource "google_storage_bucket_iam_member" "terraform_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.terraform.member
}

output "terraform_service_account" {
  value = google_service_account.terraform.email
}

output "state_bucket" {
  value = google_storage_bucket.tfstate.name
}

# ---------------------------------------------------------------------------------------------
# HCP Terraform -> Google Cloud without keys (Workload Identity Federation).
# Set both IDs (HCP: Organization settings -> General -> ID; workspace -> Settings -> ID) and
# re-apply. Names can be re-registered by someone else, IDs cannot: the condition uses IDs.
variable "hcp_organization_id" {
  type    = string
  default = ""
}

variable "hcp_workspace_id" {
  type    = string
  default = ""
}

locals {
  hcp = var.hcp_organization_id != "" && var.hcp_workspace_id != ""
}

resource "google_project_service" "sts" {
  service            = "sts.googleapis.com"
  disable_on_destroy = false
}

resource "google_iam_workload_identity_pool" "hcp" {
  count                     = local.hcp ? 1 : 0
  workload_identity_pool_id = "hcp-terraform"
  display_name              = "HCP Terraform"
  depends_on                = [google_project_service.base, google_project_service.sts]
}

resource "google_iam_workload_identity_pool_provider" "hcp" {
  count                              = local.hcp ? 1 : 0
  workload_identity_pool_id          = google_iam_workload_identity_pool.hcp[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "hcp-terraform"
  display_name                       = "app.terraform.io"

  oidc {
    # Default audience //iam.googleapis.com/<provider name>: what HCP Terraform sends when
    # TFC_GCP_WORKLOAD_PROVIDER_NAME is set.
    issuer_uri = "https://app.terraform.io"
  }

  attribute_mapping = {
    "google.subject"                      = "assertion.sub"
    "attribute.terraform_organization_id" = "assertion.terraform_organization_id"
    "attribute.terraform_workspace_id"    = "assertion.terraform_workspace_id"
    "attribute.terraform_run_phase"       = "assertion.terraform_run_phase"
  }

  # A token from any other organisation or workspace is rejected before any role is looked at.
  attribute_condition = "assertion.terraform_organization_id == \"${var.hcp_organization_id}\" && assertion.terraform_workspace_id == \"${var.hcp_workspace_id}\""
}

resource "google_service_account_iam_member" "hcp_workspace" {
  count              = local.hcp ? 1 : 0
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.hcp[0].name}/attribute.terraform_workspace_id/${var.hcp_workspace_id}"
}

# Environment variables for the spry-gcp workspace.
output "hcp_workspace_env" {
  value = local.hcp ? {
    TFC_GCP_PROVIDER_AUTH             = "true"
    TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL = google_service_account.terraform.email
    TFC_GCP_WORKLOAD_PROVIDER_NAME    = google_iam_workload_identity_pool_provider.hcp[0].name
  } : null
}
