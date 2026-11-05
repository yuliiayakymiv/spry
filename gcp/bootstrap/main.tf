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
