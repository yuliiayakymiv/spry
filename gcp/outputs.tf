output "site_url" {
  value = "https://${google_firebase_hosting_site.web.site_id}.web.app"
}

output "api_url" {
  description = "Cloud Run's own HTTPS URL (the site reaches it as /api through Firebase)"
  value       = google_cloud_run_v2_service.api.uri
}

output "image_repository" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
}

output "sql_connection_name" {
  value = google_sql_database_instance.main.connection_name
}

output "api_service_account" {
  value = google_service_account.api.email
}
