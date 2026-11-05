# APIs are off in a new project. Enabled here so that a fresh project is reproducible.
# (iam, sts, iamcredentials, cloudresourcemanager and serviceusage are enabled by gcp/bootstrap:
# the Workload Identity Federation this workspace logs in with needs them first.)
locals {
  apis = [
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "logging.googleapis.com",
  ]
}

resource "google_project_service" "api" {
  for_each = toset(local.apis)
  service  = each.value

  # terraform destroy must not switch APIs off under other things that use them.
  disable_on_destroy = false
}
