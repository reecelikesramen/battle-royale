locals {
  enabled_apis = toset([
    "cloudbuild.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "pubsub.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    # Weekly GCS pruning cron — see cleanup.tf.
    "cloudscheduler.googleapis.com",
  ])
}

resource "google_project_service" "enabled" {
  for_each = local.enabled_apis

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}
