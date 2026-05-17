#
# GCS cleanup: weekly Cloud Scheduler job hits a Cloud Function that prunes
# old release artifacts (releases/, rust-libs/, launcher/, deltas/) from the
# game-builds bucket. Keeps `latest`, the last KEEP_LAST tags, and anything
# referenced as `delta.from` in the live manifest.
#
# Source: infrastructure/cleanup-fn/. Schedule and IAM live here. Manifest
# itself, server-state.json, and any prefix not in PRUNABLE_PREFIXES are
# never touched by the function — see cleanup-fn/main.py.
#

# ─── Zip + upload function source ─────────────────────────────────────────────
data "archive_file" "cleanup_source" {
  type        = "zip"
  source_dir  = "${path.module}/../cleanup-fn"
  output_path = "${path.module}/.terraform-build/cleanup-fn.zip"
}

resource "google_storage_bucket_object" "cleanup_source" {
  name   = "cleanup-fn/source-${data.archive_file.cleanup_source.output_md5}.zip"
  bucket = google_storage_bucket.game_builds.name
  source = data.archive_file.cleanup_source.output_path
}

# ─── Runtime SA: delete objects scoped to the game-builds bucket ──────────────
resource "google_service_account" "cleanup_fn" {
  account_id   = "cleanup-fn"
  display_name = "GCS release cleanup function"
}

# objectAdmin gives both list and delete on every object in the bucket.
# The function's PRUNABLE_PREFIXES allowlist (in main.py) keeps it from
# touching versions.json / server-state.json / source archives even though
# IAM technically permits it — keep both layers as a defense-in-depth.
resource "google_storage_bucket_iam_member" "cleanup_fn_admin" {
  bucket = google_storage_bucket.game_builds.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cleanup_fn.email}"
}

# ─── The function ─────────────────────────────────────────────────────────────
resource "google_cloudfunctions2_function" "cleanup" {
  name        = "gcs-cleanup"
  location    = var.region
  description = "Prune old game-builds release artifacts on a weekly schedule."

  build_config {
    runtime     = "python312"
    entry_point = "cleanup"
    source {
      storage_source {
        bucket = google_storage_bucket.game_builds.name
        object = google_storage_bucket_object.cleanup_source.name
      }
    }
  }

  service_config {
    available_memory = "512M"
    # Listing a few thousand blobs and issuing deletes can take a minute on a
    # first run; 540s is the Cloud Functions v2 ceiling and gives plenty of
    # headroom on a wide cleanup pass.
    timeout_seconds       = 540
    max_instance_count    = 1
    service_account_email = google_service_account.cleanup_fn.email
    environment_variables = {
      BUCKET    = google_storage_bucket.game_builds.name
      KEEP_LAST = "5"
      DRY_RUN   = "0"
    }
  }

  depends_on = [
    google_storage_bucket_iam_member.cleanup_fn_admin,
    google_project_service.enabled,
  ]
}

# ─── Scheduler SA: invokes the function via OIDC ──────────────────────────────
resource "google_service_account" "cleanup_scheduler" {
  account_id   = "cleanup-scheduler"
  display_name = "Cleanup function invoker"
}

resource "google_cloud_run_v2_service_iam_member" "cleanup_invoker" {
  project  = google_cloudfunctions2_function.cleanup.project
  location = google_cloudfunctions2_function.cleanup.location
  name     = google_cloudfunctions2_function.cleanup.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.cleanup_scheduler.email}"
}

# ─── Schedule: every Monday at 09:00 UTC ──────────────────────────────────────
resource "google_cloud_scheduler_job" "cleanup_weekly" {
  name      = "gcs-cleanup-weekly"
  region    = var.region
  schedule  = "0 9 * * 1"
  time_zone = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.cleanup.service_config[0].uri
    oidc_token {
      service_account_email = google_service_account.cleanup_scheduler.email
      audience              = google_cloudfunctions2_function.cleanup.service_config[0].uri
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.cleanup_invoker,
    google_project_service.enabled,
  ]
}

output "cleanup_function_url" {
  value       = google_cloudfunctions2_function.cleanup.service_config[0].uri
  description = "POST here (manually, via OIDC token) to run the cleanup ad-hoc."
}
