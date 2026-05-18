#
# Wake endpoint: HTTPS-triggered Cloud Run Function that starts the
# game server VM. Used by the main menu "Wake server" button so testers can
# spin up the idle-shut-down server before connecting.
#
# Service URL: https://${region}-${project}.cloudfunctions.net/wake
# Backed by Cloud DNS at wake.${var.dns_zone_name} → Cloud Run URL via
# google_dns_record_set.wake_cname (below).
#

# ─── Zip + upload function source ─────────────────────────────────────────────
data "archive_file" "wake_source" {
  type        = "zip"
  source_dir  = "${path.module}/../wake-fn"
  output_path = "${path.module}/.terraform-build/wake-fn.zip"
}

resource "google_storage_bucket_object" "wake_source" {
  name   = "wake-fn/source-${data.archive_file.wake_source.output_md5}.zip"
  bucket = google_storage_bucket.game_builds.name
  source = data.archive_file.wake_source.output_path
}

# ─── Function runtime SA: can start the VM (only) ─────────────────────────────
resource "google_service_account" "wake_fn" {
  account_id   = "wake-fn"
  display_name = "Wake function runtime"
}

# Start only the game server instance. Same instance-scoped condition as the
# server's self-stop binding so the function can't be used to manipulate other VMs.
resource "google_project_iam_member" "wake_fn_start" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.wake_fn.email}"

  condition {
    title       = "start game server only"
    description = "Allow starting battle-royale-server; nothing else."
    expression  = "resource.name == 'projects/${var.project_id}/zones/${local.server_zone}/instances/battle-royale-server'"
  }
}

# Read the ready-state heartbeat. Wake-fn gates its `running` flag on this
# object so the menu "Server online" colour reflects actual game readiness
# rather than VM-status RUNNING. Path-scoped — wake-fn can't read any other
# bucket contents.
resource "google_storage_bucket_iam_member" "wake_fn_read_state" {
  bucket = google_storage_bucket.game_builds.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.wake_fn.email}"

  condition {
    title       = "server-state object only"
    description = "Wake-fn may only read server-state.json."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.game_builds.name}/objects/server-state.json\")"
  }
}

# ─── The function ─────────────────────────────────────────────────────────────
resource "google_cloudfunctions2_function" "wake" {
  name        = "wake"
  location    = var.region
  description = "Start the game server VM on demand."

  build_config {
    runtime     = "python312"
    entry_point = "wake"
    source {
      storage_source {
        bucket = google_storage_bucket.game_builds.name
        object = google_storage_bucket_object.wake_source.name
      }
    }
  }

  service_config {
    available_memory      = "256M"
    timeout_seconds       = 60
    max_instance_count    = 4
    service_account_email = google_service_account.wake_fn.email
    environment_variables = {
      PROJECT_ID    = var.project_id
      INSTANCE_NAME = "battle-royale-server"
      INSTANCE_ZONE = local.server_zone
      # Ready-state heartbeat the agent publishes — wake-fn uses this to
      # report `running` only when the game is actually accepting clients.
      STATE_BUCKET = google_storage_bucket.game_builds.name
      STATE_OBJECT = "server-state.json"
      # WAKE_SECRET intentionally unset by default; set via terraform.tfvars +
      # a separate google_secret_manager_secret if you need auth.
    }
  }

  depends_on = [
    google_project_iam_member.wake_fn_start,
    google_storage_bucket_iam_member.wake_fn_read_state,
    google_project_service.enabled,
  ]
}

# Make the function publicly invokable (HTTP). Keep WAKE_SECRET unset == open.
resource "google_cloud_run_v2_service_iam_member" "wake_public" {
  project  = google_cloudfunctions2_function.wake.project
  location = google_cloudfunctions2_function.wake.location
  name     = google_cloudfunctions2_function.wake.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "wake_function_url" {
  value       = google_cloudfunctions2_function.wake.service_config[0].uri
  description = "POST here to start the VM. Plumb into godot/server/wake_client.gd."
}
