# Firebase Hosting: the static frontend, CDN and managed HTTPS on <project>.web.app.
# /api/** is rewritten to the Cloud Run service (firebase.json): one origin, no CORS.
resource "google_firebase_project" "main" {
  provider = google-beta
  project  = var.project_id

  depends_on = [google_project_service.api]
}

resource "google_firebase_hosting_site" "web" {
  provider = google-beta
  project  = var.project_id
  site_id  = var.project_id

  depends_on = [google_firebase_project.main]
}
