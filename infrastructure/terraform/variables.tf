variable "project_id" {
  type        = string
  description = "GCP project id. Default mirrors the existing live project."
  default     = "erudite-cycle-480104"
}

variable "region" {
  type        = string
  description = "Primary region for regional resources (bucket location, VM, etc.)."
  default     = "us-central1"
}

variable "bucket_name" {
  type        = string
  description = "GCS bucket holding builds, releases, rust libs, godot import cache, signed manifest."
  default     = "erudite-cycle-480104-game-builds"
}

variable "state_bucket_name" {
  type        = string
  description = "GCS bucket holding terraform state. Must exist before `terraform init` (see infrastructure/bootstrap.sh)."
  default     = "erudite-cycle-480104-tfstate"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo in `owner/name` form. Used by Cloud Build connections in a later sprint; informational for now."
  default     = "reecelikesramen/battle-royale"
}

variable "manifest_signing_key_pub_path" {
  type        = string
  description = "Path (relative to terraform/) to the committed ed25519 public key. Generated in Sprint 2."
  default     = "../keys/manifest_pub.ed25519"
}

variable "ssh_source_ranges" {
  type        = list(string)
  description = "CIDR ranges allowed to SSH to the game server VM. Default is open; tighten in terraform.tfvars."
  default     = ["0.0.0.0/0"]
}

variable "dns_zone_name" {
  type        = string
  description = "DNS name of the Cloud DNS managed zone for the game server subdomain."
  default     = "server.pywire.dev"
}

variable "cloudflare_pywire_zone_id" {
  type        = string
  description = "Cloudflare zone id for pywire.dev. Get with `flarectl zone list` or from the dashboard. Required only if managing the NS delegation from this Terraform."
  default     = ""
}
