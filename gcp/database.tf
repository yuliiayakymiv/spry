# Cloud SQL for PostgreSQL, smallest shared-core tier. It does NOT pause on idle (unlike Aurora):
# it bills every hour it runs. Stop it with db_activation_policy = "NEVER".
resource "google_sql_database_instance" "main" {
  name             = "${var.project_name}-db"
  database_version = "POSTGRES_17"
  region           = var.region

  settings {
    # db-f1-micro exists only in the Enterprise edition (PostgreSQL 16+ defaults to Enterprise Plus).
    edition           = "ENTERPRISE"
    tier              = var.db_tier
    availability_type = "ZONAL"
    activation_policy = var.db_activation_policy
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = false

    ip_configuration {
      # A public IP with NO authorised networks: nothing can connect over the network. Cloud Run
      # reaches it through the Cloud SQL connector (IAM-authorised, TLS, a unix socket in the
      # container). A private IP would need a VPC and a connector: more cost, nothing gained here.
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled = false # a lab database: no backup storage on the bill
    }
  }

  # Lab: `terraform destroy` must remove everything. A real environment keeps this true.
  deletion_protection = false

  depends_on = [google_project_service.api]
}

resource "google_sql_database" "app" {
  name     = "meetings"
  instance = google_sql_database_instance.main.name
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  name     = "meetings"
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
}

# The password is generated here and lives only in Secret Manager (and the Terraform state, which is
# encrypted in HCP Terraform). The API reads the whole connection string from the secret.
resource "google_secret_manager_secret" "database_url" {
  secret_id = "${var.project_name}-database-url"

  replication {
    auto {}
  }

  depends_on = [google_project_service.api]
}

resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.database_url.id
  # asyncpg over the unix socket that Cloud Run mounts at /cloudsql/<connection name>.
  secret_data = "postgresql+asyncpg://${google_sql_user.app.name}:${random_password.db.result}@/${google_sql_database.app.name}?host=/cloudsql/${google_sql_database_instance.main.connection_name}"
}
