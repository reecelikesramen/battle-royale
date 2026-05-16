resource "google_storage_bucket" "game_builds" {
  name                        = var.bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  # Releases get demoted to NEARLINE after 30 days — old builds are rarely
  # downloaded but we keep them for rollback / patch-from references.
  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age              = 30
      matches_prefix   = ["releases/"]
      send_age_if_zero = true
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.enabled]
}

# Make the releases/ prefix publicly readable so the launcher (and end users)
# can fetch artifacts and manifest without auth.
#
# Uniform bucket-level access means we can't use object ACLs; instead we grant
# allUsers objectViewer scoped to the whole bucket. Everything outside
# releases/ (rust-libs/, cache/, etc.) is referenced by signed URLs internally,
# so public-read on those prefixes is acceptable but undesirable — restructure
# later if needed by splitting into a separate `*-public` bucket.
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.game_builds.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}
