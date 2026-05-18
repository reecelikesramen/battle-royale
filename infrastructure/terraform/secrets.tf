# Manifest signing key — PEM-encoded ed25519 private key.
#
# The secret resource is managed by Terraform. The secret *version* (the actual
# key material) is uploaded out-of-band via `infrastructure/keys/generate-signing-key.sh`
# so the private key never touches disk in the repo or in Terraform state.
resource "google_secret_manager_secret" "manifest_signing_key" {
  secret_id = "manifest-signing-key"

  labels = {
    purpose = "manifest-signing"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

# Cloud Build runs as the Compute Engine default SA. Give it read access to
# the signing key so the signing step can sign versions.json.
resource "google_secret_manager_secret_iam_member" "cloudbuild_can_read_signing_key" {
  secret_id = google_secret_manager_secret.manifest_signing_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.compute_default_sa}"
}
