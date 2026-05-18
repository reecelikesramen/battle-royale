data "google_project" "current" {
  project_id = var.project_id
}

locals {
  compute_default_sa = "${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

# ─── GitHub Actions builder SA ────────────────────────────────────────────────
# Used by .github/workflows/godot-google-ci.yml to upload Rust libs to GCS and
# trigger Cloud Build runs.
resource "google_service_account" "github_actions_builder" {
  account_id   = "github-actions-builder"
  display_name = "GitHub Actions Builder"
  description  = "Used by GitHub Actions to upload artifacts and submit Cloud Builds."
}

resource "google_project_iam_member" "builder_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.github_actions_builder.email}"
}

resource "google_project_iam_member" "builder_cloudbuild" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${google_service_account.github_actions_builder.email}"
}

resource "google_project_iam_member" "builder_serviceusage" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = "serviceAccount:${google_service_account.github_actions_builder.email}"
}

# ─── Compute Engine default SA (Cloud Build runs as this) ─────────────────────
resource "google_project_iam_member" "compute_sa_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${local.compute_default_sa}"
}

# Builder SA can impersonate Compute default SA so `gcloud builds submit` works.
resource "google_service_account_iam_member" "builder_impersonates_compute" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.compute_default_sa}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.github_actions_builder.email}"
}
