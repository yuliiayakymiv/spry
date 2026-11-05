terraform {
  required_version = ">= 1.10"

  # Its own state, separate from infra/ (HCP Terraform workspace spry-dev), so that one plan can
  # never touch both clouds. In a versioned Cloud Storage bucket created by gcp/bootstrap, because
  # access to the HCP Terraform account was lost (ADR 0008). Moving it to an HCP workspace later is a
  # `cloud {}` block + `terraform init -migrate-state`.
  backend "gcs" {
    bucket                      = "spry-yuliia-2026-tfstate"
    prefix                      = "gcp"
    impersonate_service_account = "terraform@spry-yuliia-2026.iam.gserviceaccount.com"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.10"
    }
    # Firebase project and Hosting site are google-beta resources.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

# Credentials: no keys. A person runs it with their own gcloud login, and every call is made AS the
# service account `terraform@` (impersonation: a short-lived token, only its roles), so the plan can
# do exactly what that account may do and nothing more.
provider "google" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = "terraform@${var.project_id}.iam.gserviceaccount.com"

  default_labels = {
    project    = var.project_name
    managed-by = "terraform"
  }
}

provider "google-beta" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = "terraform@${var.project_id}.iam.gserviceaccount.com"
  # The Firebase Management API bills quota to a project; ours, not the caller's default.
  user_project_override = true
  billing_project       = var.project_id
}
