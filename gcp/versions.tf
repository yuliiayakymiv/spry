terraform {
  required_version = ">= 1.10"

  # Its own state: a second HCP Terraform workspace, separate from infra/ (spry-dev), so that one
  # plan can never touch both clouds.
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

# Credentials: none here. In HCP Terraform the run gets a short-lived token of the service account
# `terraform@` through Workload Identity Federation (workspace env vars TFC_GCP_*, gcp/bootstrap).
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
}
