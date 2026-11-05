# Run ONCE, by a person, with their own gcloud login (application default credentials) and local
# state, e.g. from Cloud Shell:  terraform init && terraform apply -var project_id=... -var ...
# It creates what HCP Terraform needs to log in to Google Cloud without any stored key:
#   - the service account `terraform@` with only the roles gcp/ needs (no Owner / Editor);
#   - a workload identity pool + OIDC provider that trusts HCP Terraform's run tokens,
#     admitting only ONE organisation and ONE workspace, by their immutable IDs;
#   - Workload Identity User on the service account for that workspace.
# No service account key is ever created.

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

variable "hcp_organization_id" {
  type        = string
  description = "org-... (HCP Terraform -> Organization settings -> General -> ID). Names can be re-registered, IDs cannot."
}

variable "hcp_workspace_id" {
  type        = string
  description = "ws-... of the spry-gcp workspace"
}

provider "google" {
  project = var.project_id
}

data "google_project" "this" {}

resource "google_project_service" "base" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

resource "google_service_account" "terraform" {
  account_id   = "terraform"
  display_name = "Terraform (HCP Terraform workspace spry-gcp)"
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
    # what gcp/ also creates: the API's own service account and its two role bindings,
    # and the Firebase project + Hosting site
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

resource "google_iam_workload_identity_pool" "hcp" {
  workload_identity_pool_id = "hcp-terraform"
  display_name              = "HCP Terraform"
  depends_on                = [google_project_service.base]
}

resource "google_iam_workload_identity_pool_provider" "hcp" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.hcp.workload_identity_pool_id
  workload_identity_pool_provider_id = "hcp-terraform"
  display_name                       = "app.terraform.io"

  oidc {
    issuer_uri = "https://app.terraform.io"
    # Default audience: //iam.googleapis.com/<this provider's full name>, which is what HCP
    # Terraform sends when TFC_GCP_WORKLOAD_PROVIDER_NAME is set.
  }

  attribute_mapping = {
    "google.subject"                       = "assertion.sub"
    "attribute.terraform_organization_id"  = "assertion.terraform_organization_id"
    "attribute.terraform_workspace_id"     = "assertion.terraform_workspace_id"
    "attribute.terraform_run_phase"        = "assertion.terraform_run_phase"
  }

  # Tokens from any other organisation or workspace are rejected before any role is considered.
  attribute_condition = "assertion.terraform_organization_id == \"${var.hcp_organization_id}\" && assertion.terraform_workspace_id == \"${var.hcp_workspace_id}\""
}

resource "google_service_account_iam_member" "hcp_workspace" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.hcp.name}/attribute.terraform_workspace_id/${var.hcp_workspace_id}"
}

# Paste these three into the spry-gcp workspace as environment variables.
output "workspace_env" {
  value = {
    TFC_GCP_PROVIDER_AUTH             = "true"
    TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL = google_service_account.terraform.email
    TFC_GCP_WORKLOAD_PROVIDER_NAME    = google_iam_workload_identity_pool_provider.hcp.name
  }
}
