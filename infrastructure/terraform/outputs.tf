output "project_id" {
  value = var.project_id
}

output "bucket_name" {
  value = google_storage_bucket.game_builds.name
}

output "github_actions_sa_email" {
  value       = google_service_account.github_actions_builder.email
  description = "Set as the principal for GCP_SA_KEY in GitHub Actions secrets (key creation is a manual gcloud step — see README)."
}

output "compute_default_sa_email" {
  value = local.compute_default_sa
}
