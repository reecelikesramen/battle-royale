terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.40"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Cloudflare provider — only manages the `server` NS records inside the
# pywire.dev zone. Does NOT manage the zone itself or any other records;
# the bulk of pywire.dev DNS lives in ~/projects/pywire.dev/infra and stays
# there. Authenticate via the CLOUDFLARE_API_TOKEN env var (token scoped to
# Zone:DNS:Edit for pywire.dev only).
provider "cloudflare" {}
