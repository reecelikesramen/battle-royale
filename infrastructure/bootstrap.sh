#!/usr/bin/env bash
#
# One-shot bootstrap: creates the GCS bucket that holds Terraform state.
# Run this once before the first `terraform init`. After that, Terraform
# manages everything else.
#
# Idempotent: re-running on an existing state bucket is a no-op.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-erudite-cycle-480104}"
REGION="${REGION:-us-central1}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tfstate}"

echo "Bootstrapping Terraform state bucket..."
echo "  project:       $PROJECT_ID"
echo "  region:        $REGION"
echo "  state bucket:  gs://$STATE_BUCKET"
echo

gcloud config set project "$PROJECT_ID"

if gsutil ls -b "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  echo "State bucket already exists. Nothing to do."
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --public-access-prevention
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
  echo "State bucket created with versioning enabled."
fi

echo
echo "Next steps:"
echo "  cd infrastructure/terraform"
echo "  cp terraform.tfvars.example terraform.tfvars  # edit if needed"
echo "  terraform init"
echo "  # then import existing resources per infrastructure/README.md"
