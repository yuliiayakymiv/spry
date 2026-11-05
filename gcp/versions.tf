terraform {
  required_version = ">= 1.10"

  # Its own state: a second HCP Terraform workspace next to infra/'s spry-dev, so that one plan
  # can never touch both clouds. (For the first apply the state was in gs://spry-yuliia-2026-tfstate
  # while the HCP account was locked; moved with `terraform init -migrate-state`.)
  cloud {
    organization = "ooad-yuliiayakymiv"

    workspaces {
      name = "spry-gcp"
    }
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

# Credentials: none here, no keys anywhere. A run in HCP Terraform presents its signed OIDC token to
# Google (Workload Identity Federation, gcp/bootstrap) and gets a short-lived token of the service
# account terraform@ — only for this organisation and this workspace, matched by their IDs.
# Workspace env vars: TFC_GCP_PROVIDER_AUTH, TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL,
# TFC_GCP_WORKLOAD_PROVIDER_NAME.
provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project    = var.project_name
    managed-by = "terraform"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  # The Firebase Management API bills quota to a project; ours, not the caller's default.
  user_project_override = true
  billing_project       = var.project_id
}
