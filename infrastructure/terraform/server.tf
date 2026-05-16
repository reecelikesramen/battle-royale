locals {
  server_zone     = "${var.region}-a"
  server_hostname = "playtest"
}

# ─── Runtime service account for the game server VM ───────────────────────────
resource "google_service_account" "game_server" {
  account_id   = "battle-royale-server"
  display_name = "Battle Royale game server"
  description  = "Runs on the GCE VM. Reads release artifacts from GCS, writes player-count metrics to Cloud Monitoring, can stop itself when idle."
}

# Read game artifacts (Sprint 5: PCKs, binaries; Sprint 2: signed manifest).
resource "google_storage_bucket_iam_member" "server_can_read_builds" {
  bucket = google_storage_bucket.game_builds.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.game_server.email}"
}

# Write custom metrics (Sprint 6).
resource "google_project_iam_member" "server_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.game_server.email}"
}

# Read custom metrics back. The server-agent queries the players_connected
# metric every 60s to decide whether to fire idle shutdown — without viewer
# the read returns 403 and the agent treats every poll as "unknown → active",
# so idle never accumulates and the VM never auto-stops.
resource "google_project_iam_member" "server_metric_reader" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.game_server.email}"
}

# Stop self (Sprint 6 idle shutdown). Scoped via IAM condition so the SA can
# only act on this specific instance — exfiltrated tokens can't manage the
# rest of the project.
resource "google_project_iam_member" "server_compute_self_stop" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.game_server.email}"

  condition {
    title       = "self-stop only"
    description = "Permits compute operations only on the battle-royale-server instance."
    expression  = "resource.name == 'projects/${var.project_id}/zones/${local.server_zone}/instances/battle-royale-server'"
  }
}

# ─── Networking ───────────────────────────────────────────────────────────────
resource "google_compute_address" "game_server" {
  name         = "game-server-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "STANDARD"

  depends_on = [google_project_service.enabled]
}

resource "google_compute_firewall" "game_server_udp" {
  name    = "allow-game-server-udp"
  network = "default"

  allow {
    protocol = "udp"
    ports    = ["45876"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["game-server"]

  depends_on = [google_project_service.enabled]
}

resource "google_compute_firewall" "game_server_ssh" {
  name    = "allow-game-server-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # OS Login from the operator's IP. Replace with a tighter range in
  # terraform.tfvars by overriding var.ssh_source_ranges.
  source_ranges = var.ssh_source_ranges
  target_tags   = ["game-server"]

  depends_on = [google_project_service.enabled]
}

# ─── Instance ─────────────────────────────────────────────────────────────────
resource "google_compute_instance" "game_server" {
  name         = "battle-royale-server"
  machine_type = "e2-small"
  zone         = local.server_zone
  tags         = ["game-server"]

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {
      nat_ip       = google_compute_address.game_server.address
      network_tier = "STANDARD"
    }
  }

  metadata = {
    # First-boot installer script. Subsequent reboots re-run only the parts
    # that are idempotent (refresh.sh).
    startup-script = templatefile("${path.module}/server-files/startup.sh", {
      bucket            = var.bucket_name
      project_id        = var.project_id
      service_unit_body = file("${path.module}/server-files/battle-royale-server.service")
      agent_unit_body   = file("${path.module}/server-files/battle-royale-agent.service")
      refresh_script    = file("${path.module}/server-files/refresh.sh")
      manifest_pub_b64  = filebase64(var.manifest_signing_key_pub_path)
    })
  }

  service_account {
    email  = google_service_account.game_server.email
    scopes = ["cloud-platform"]
  }

  # Allow Terraform to manage the VM safely; idle-shutdown stops it but does
  # not delete.
  allow_stopping_for_update = true
  deletion_protection       = false

  depends_on = [
    google_project_service.enabled,
    google_storage_bucket_iam_member.server_can_read_builds,
  ]
}

output "game_server_ip" {
  value       = google_compute_address.game_server.address
  description = "Static public IP of the game server VM. DNS A record points here."
}

output "game_server_address" {
  value       = "${local.server_hostname}.server.pywire.dev"
  description = "Connect from the game client to this hostname."
}
