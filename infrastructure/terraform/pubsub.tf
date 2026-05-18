#
# Pub/Sub release notifications. Cloud Build publishes to this topic on every
# successful release; the VM's server-agent subscribes and triggers a
# graceful restart so the server picks up the new version.
#
resource "google_pubsub_topic" "game_builds" {
  name = "game-builds"

  depends_on = [google_project_service.enabled]
}

resource "google_pubsub_subscription" "server_listener" {
  name  = "battle-royale-server-release"
  topic = google_pubsub_topic.game_builds.name

  # Generous deadline so a slow drain + restart doesn't trigger redelivery
  # (drain is up to 30s, sleep buffer 5s, systemctl restart can take 10s).
  ack_deadline_seconds = 120

  # Pull subscription — the agent calls `subscriptions.pull` from a
  # long-poll loop. No push endpoint, no extra IAM surface.
  message_retention_duration = "600s"
  retain_acked_messages      = false

  expiration_policy {
    ttl = "" # never expire
  }
}

# Cloud Build (running as Compute Engine default SA) needs to publish.
resource "google_pubsub_topic_iam_member" "cloudbuild_publishes" {
  topic  = google_pubsub_topic.game_builds.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${local.compute_default_sa}"
}

# Game-server runtime SA subscribes.
resource "google_pubsub_subscription_iam_member" "server_subscribes" {
  subscription = google_pubsub_subscription.server_listener.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.game_server.email}"
}
