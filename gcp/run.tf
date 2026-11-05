resource "google_artifact_registry_repository" "app" {
  repository_id = var.project_name
  location      = var.region
  format        = "DOCKER"

  # Keep the free 0.5 GB: only the last 3 images.
  cleanup_policies {
    id     = "keep-last-3"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }
  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition {
      older_than = "86400s"
    }
  }

  depends_on = [google_project_service.api]
}

# The API runs as its own service account (not the default compute one, which has Editor).
resource "google_service_account" "api" {
  account_id   = "${var.project_name}-api"
  display_name = "Spry API on Cloud Run"
}

resource "google_project_iam_member" "api_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.api.member
}

resource "google_secret_manager_secret_iam_member" "api_database_url" {
  secret_id = google_secret_manager_secret.database_url.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.api.member
}

resource "google_cloud_run_v2_service" "api" {
  name                = "${var.project_name}-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.api.email

    scaling {
      min_instance_count = 0 # scales to zero: an idle month costs nothing
      max_instance_count = 2 # db-f1-micro has ~25 connections; caps the bill too
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      # Two roads, as in Lab 7: Terraform owns the service, the application road
      # (gcp/deploy.sh: Cloud Build -> Artifact Registry -> gcloud run deploy) owns the image.
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      ports {
        container_port = 8080 # Cloud Run sends HTTP to $PORT; the Dockerfile listens on it
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true # request-based billing: CPU only while a request is handled
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "COGNITO_ISSUER"
        value = var.cognito_issuer
      }
      env {
        name  = "COGNITO_CLIENT_ID"
        value = var.cognito_client_id
      }
      env {
        name  = "CORS_ORIGINS"
        value = "https://${var.project_id}.web.app,https://${var.project_id}.firebaseapp.com,http://localhost:5173"
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        tcp_socket {
          port = 8080
        }
        initial_delay_seconds = 0
        period_seconds        = 3
        failure_threshold     = 20 # `alembic upgrade head` runs before uvicorn starts
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_project_service.api,
    google_secret_manager_secret_iam_member.api_database_url,
    google_project_iam_member.api_sql,
    # "latest" must exist when the first revision starts: the version needs the DB user first.
    google_secret_manager_secret_version.database_url,
  ]
}

# Public, because the API checks Cognito tokens itself (every /api route except /api/health).
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
