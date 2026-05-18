# Infrastructure

Terraform-managed GCP resources for the Battle Royale build pipeline (and, in
later sprints, the cloud-hosted dedicated server, DNS, Pub/Sub release
notifications, and metrics).

Sprint 1 imports the existing project state — created originally by
`cloudbuild-setup.sh` (now removed) — without changing live behavior.

## Layout

```
infrastructure/
├── bootstrap.sh                   # Creates the GCS bucket holding tf state. Run once.
├── keys/
│   └── manifest_pub.ed25519       # Committed manifest-signing public key (added in Sprint 2)
└── terraform/
    ├── versions.tf                # Provider pins
    ├── variables.tf               # Inputs (project_id, region, bucket names, ...)
    ├── backend.tf                 # GCS backend for state
    ├── apis.tf                    # google_project_service for every API we use
    ├── buckets.tf                 # game-builds bucket + allUsers read binding
    ├── iam.tf                     # SA + role bindings (mirrors cloudbuild-setup.sh)
    ├── cloudbuild.tf              # Placeholder — see comment inside
    ├── outputs.tf
    └── terraform.tfvars.example
```

## First-time setup on a fresh machine

```bash
# 1. Auth as a user with project-owner on the target GCP project.
gcloud auth login
gcloud auth application-default login
gcloud config set project erudite-cycle-480104

# 2. Bootstrap the state bucket (idempotent).
./infrastructure/bootstrap.sh

# 3. Init Terraform.
cd infrastructure/terraform
cp terraform.tfvars.example terraform.tfvars   # edit if you're using a different project
terraform init

# 4. (First time on the live project only) Import existing resources.
#    See the "Importing existing state" section below.

# 5. Verify zero drift.
terraform plan
```

## Importing existing state

The live project already has every resource declared here. Import each one
before the first `terraform apply` so Terraform doesn't try to create
duplicates.

```bash
# API enablements (one per service). Repeat for each entry in apis.tf.
terraform import \
  'google_project_service.enabled["cloudbuild.googleapis.com"]' \
  erudite-cycle-480104/cloudbuild.googleapis.com
# ...and the rest: storage, iam, iamcredentials, serviceusage, compute,
# dns, pubsub, monitoring, secretmanager, cloudfunctions, run,
# artifactregistry. (DNS/pubsub/secretmanager/cloudfunctions/run may not yet
# be enabled — `terraform apply` will enable them.)

# Buckets.
terraform import google_storage_bucket.game_builds erudite-cycle-480104-game-builds

# Verify storage class before/after import — should be STANDARD.
gsutil ls -Lb gs://erudite-cycle-480104-game-builds | grep -i 'storage class'

# Public-read binding: only import if it exists. The original
# cloudbuild-setup.sh tried to grant public read via object ACLs, but
# Uniform Bucket-Level Access silently rejected that. Check before importing:
gcloud storage buckets get-iam-policy gs://erudite-cycle-480104-game-builds \
  --format=json | jq '.bindings[] | select(.role == "roles/storage.objectViewer")'
# If the output shows `allUsers`, run:
#   terraform import google_storage_bucket_iam_member.public_read \
#     "b/erudite-cycle-480104-game-builds roles/storage.objectViewer allUsers"
# If the output is empty, skip the import — first `terraform apply` will
# create the binding (restoring/creating the public-read access the launcher
# and existing init.gd flow depend on for fetching versions.json).

# Service account.
terraform import google_service_account.github_actions_builder \
  projects/erudite-cycle-480104/serviceAccounts/github-actions-builder@erudite-cycle-480104.iam.gserviceaccount.com

# Project IAM bindings.
PROJECT_NUMBER="$(gcloud projects describe erudite-cycle-480104 --format='value(projectNumber)')"
test -n "$PROJECT_NUMBER" || { echo "PROJECT_NUMBER empty; bail"; exit 1; }
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
BUILDER_SA="github-actions-builder@erudite-cycle-480104.iam.gserviceaccount.com"
echo "COMPUTE_SA=$COMPUTE_SA"
echo "BUILDER_SA=$BUILDER_SA"

terraform import google_project_iam_member.builder_storage \
  "erudite-cycle-480104 roles/storage.objectAdmin serviceAccount:${BUILDER_SA}"
terraform import google_project_iam_member.builder_cloudbuild \
  "erudite-cycle-480104 roles/cloudbuild.builds.editor serviceAccount:${BUILDER_SA}"
terraform import google_project_iam_member.builder_serviceusage \
  "erudite-cycle-480104 roles/serviceusage.serviceUsageConsumer serviceAccount:${BUILDER_SA}"
terraform import google_project_iam_member.compute_sa_storage \
  "erudite-cycle-480104 roles/storage.objectAdmin serviceAccount:${COMPUTE_SA}"

# SA impersonation binding.
terraform import google_service_account_iam_member.builder_impersonates_compute \
  "projects/erudite-cycle-480104/serviceAccounts/${COMPUTE_SA} roles/iam.serviceAccountUser serviceAccount:${BUILDER_SA}"
```

After every import, run `terraform plan` and verify the output says
**"No changes."** If it shows attribute diffs, edit the `.tf` to match live
state rather than letting Terraform overwrite live config.

## GitHub secrets

The pipeline expects three GitHub Actions variables and one secret:

| Kind     | Name             | Source                                                 |
|----------|------------------|--------------------------------------------------------|
| Variable | `GCP_PROJECT_ID` | `terraform output -raw project_id`                     |
| Variable | `GCP_REGION`     | Same as `var.region`                                   |
| Variable | `GCS_BUCKET`     | `terraform output -raw bucket_name`                    |
| Secret   | `GCP_SA_KEY`     | JSON key for `github_actions_sa_email`. **Not** managed by Terraform — generate manually and rotate periodically. |

To create a fresh key (and delete the old one) for rotation:

```bash
SA="$(terraform output -raw github_actions_sa_email)"
gcloud iam service-accounts keys create gh-sa-key.json --iam-account="$SA"
# Paste contents into GitHub → Settings → Secrets → Actions → GCP_SA_KEY
shred -u gh-sa-key.json
# Old keys: list with `gcloud iam service-accounts keys list --iam-account=$SA`
#           delete with `gcloud iam service-accounts keys delete <KEY_ID> --iam-account=$SA`
```

## Verifying the import worked

After import, push a no-op commit to `main` and tag `vX.Y.Z-test`. The
existing GitHub Actions workflow should run end-to-end (Rust matrix → GCS
upload → Cloud Build → release artifacts) with no changes in behavior.

## Manifest signing (Sprint 2)

The launcher verifies `versions.json` against an ed25519 signature. The
signing flow:

1. `terraform apply` creates an empty `manifest-signing-key` Secret Manager
   secret and grants Cloud Build access (see `terraform/secrets.tf`).
2. Once, run `infrastructure/keys/generate-signing-key.sh` to generate a
   keypair. The script writes the public key to
   `infrastructure/keys/manifest_pub.ed25519` (commit it) and prints the
   PEM private key for you to upload via `gcloud secrets versions add`.
3. On every release, Cloud Build pulls the latest secret version, signs
   `versions.json`, and uploads `versions-v2.json.sig`.
4. The launcher (Sprint 3+) downloads both, verifies the signature with its
   embedded copy of the public key, then trusts the per-component sha256s
   inside.

A 32-byte all-zero placeholder pubkey ships in the repo so the launcher
builds before you generate the real key. Replace it before the first signed
release.

## Notes / known issues

- **Public read scope.** Originally `cloudbuild-setup.sh` tried to scope public
  read to `releases/` only, but Uniform Bucket-Level Access doesn't support
  prefix-scoped ACLs. The bucket is currently fully public-read. Non-sensitive
  in scope today (only build artifacts + Godot import cache), but a future
  cleanup should split into a private bucket + a `*-public` mirror for
  releases.
- **No Cloud Build trigger resource.** Builds are submitted by GH Actions
  using `gcloud builds submit`. Migrating to a persistent trigger (which would
  let us drop the GCP_SA_KEY secret) is tracked separately.
