resource "google_dns_managed_zone" "server" {
  name        = "server-pywire-dev"
  dns_name    = "${var.dns_zone_name}."
  description = "Game server subdomain. Delegated from Cloudflare via NS records (see outputs)."

  depends_on = [google_project_service.enabled]
}

resource "google_dns_record_set" "playtest_a" {
  managed_zone = google_dns_managed_zone.server.name
  name         = "${local.server_hostname}.${var.dns_zone_name}."
  type         = "A"
  ttl          = 60

  rrdatas = [google_compute_address.game_server.address]
}

output "cloudflare_ns_records_to_add" {
  description = "GCP nameservers that need NS records in Cloudflare. Auto-applied below when cloudflare_pywire_zone_id is set; otherwise paste into your pywire.dev TF manually."
  value       = google_dns_managed_zone.server.name_servers
}

# Delegate `server.pywire.dev` to GCP Cloud DNS. Scoped strictly to these
# four NS records — the rest of pywire.dev's DNS lives in
# ~/projects/pywire.dev/infra and is untouched. Skip if zone id not set.
resource "cloudflare_record" "server_ns" {
  # Static keys (0..3) because the name_servers values are only known after
  # the GCP zone is created — for_each cannot use apply-time-derived sets.
  for_each = var.cloudflare_pywire_zone_id == "" ? toset([]) : toset(["0", "1", "2", "3"])

  zone_id = var.cloudflare_pywire_zone_id
  name    = "server"
  type    = "NS"
  # Cloudflare stores NS values without trailing dot; GCP returns them with one.
  value   = trimsuffix(google_dns_managed_zone.server.name_servers[tonumber(each.key)], ".")
  ttl     = 3600
  proxied = false # NS records cannot be proxied
}
