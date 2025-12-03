#!/bin/bash
set -e

# ============ CONFIGURATION ============
PROJECT_ID="erudite-cycle-480104"
BUCKET_NAME="${PROJECT_ID}-game-builds"  # Uses project ID for global uniqueness
REGION="us-central1"
SA_NAME="github-actions-builder"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
GODOT_VERSION="4.5"

echo "Setting up GCP project: $PROJECT_ID"

# ============ SET PROJECT ============
gcloud config set project $PROJECT_ID

# ============ ENABLE REQUIRED APIS ============
echo "Enabling APIs..."
gcloud services enable \
  cloudbuild.googleapis.com \
  storage.googleapis.com \
  artifactregistry.googleapis.com

# ============ CREATE GCS BUCKET ============
echo "Creating GCS bucket: $BUCKET_NAME"
if gsutil ls -b gs://$BUCKET_NAME 2>/dev/null; then
  echo "Bucket already exists and is accessible"
else
  gcloud storage buckets create gs://$BUCKET_NAME \
    --location=$REGION \
    --uniform-bucket-level-access
  echo "Bucket created"
fi

# Verify bucket is accessible
if ! gsutil ls -b gs://$BUCKET_NAME >/dev/null 2>&1; then
  echo "ERROR: Cannot access bucket gs://$BUCKET_NAME"
  echo "The bucket name may be taken by another project globally."
  echo "Try a different BUCKET_NAME in the script."
  exit 1
fi

# Create folder structure
echo "Creating folder structure..."
echo "" | gsutil cp - gs://$BUCKET_NAME/rust-libs/.keep
echo "" | gsutil cp - gs://$BUCKET_NAME/cache/.keep
echo "" | gsutil cp - gs://$BUCKET_NAME/releases/.keep

# Make releases folder public
echo "Making releases folder public..."
gsutil -m acl ch -r -u AllUsers:R gs://$BUCKET_NAME/releases/ 2>/dev/null || true
gsutil defacl ch -u AllUsers:R gs://$BUCKET_NAME/releases/ 2>/dev/null || true

# ============ CREATE SERVICE ACCOUNT ============
echo "Creating service account: $SA_EMAIL"
if gcloud iam service-accounts describe $SA_EMAIL >/dev/null 2>&1; then
  echo "Service account already exists"
else
  gcloud iam service-accounts create $SA_NAME \
    --display-name="GitHub Actions Builder"
  echo "Service account created, waiting for propagation..."
  sleep 10
fi

# Verify service account exists
if ! gcloud iam service-accounts describe $SA_EMAIL >/dev/null 2>&1; then
  echo "ERROR: Service account $SA_EMAIL does not exist"
  echo "Try running the script again in a minute"
  exit 1
fi

# Grant permissions
echo "Granting permissions..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/storage.objectAdmin" \
  --condition=None \
  --quiet

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/cloudbuild.builds.editor" \
  --condition=None \
  --quiet

# Required to access Cloud Build staging bucket
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --condition=None \
  --quiet

# ============ CREATE SERVICE ACCOUNT KEY ============
echo "Creating service account key..."
KEY_FILE="github-sa-key-${PROJECT_ID}.json"
gcloud iam service-accounts keys create $KEY_FILE \
  --iam-account=$SA_EMAIL

# Grant Cloud Build service account storage access for its default bucket
echo "Granting Cloud Build permissions..."
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$CLOUDBUILD_SA" \
  --role="roles/storage.objectAdmin" \
  --condition=None \
  --quiet

# ============ SUMMARY ============
echo ""
echo "============================================"
echo "SETUP COMPLETE!"
echo "============================================"
echo ""
echo "GCP Project:     $PROJECT_ID"
echo "GCS Bucket:      gs://$BUCKET_NAME"
echo "Region:          $REGION"
echo "Service Account: $SA_EMAIL"
echo ""
echo "Using public Docker image: barichello/godot-ci:$GODOT_VERSION"
echo ""
echo "============================================"
echo "GITHUB REPOSITORY VARIABLES (Settings → Secrets and variables → Actions → Variables):"
echo "============================================"
echo "GCP_PROJECT_ID = $PROJECT_ID"
echo "GCP_REGION     = $REGION"
echo "GCS_BUCKET     = $BUCKET_NAME"
echo ""
echo "============================================"
echo "GITHUB REPOSITORY SECRET (Settings → Secrets and variables → Actions → Secrets):"
echo "============================================"
echo "GCP_SA_KEY = (contents of $KEY_FILE)"
echo ""
echo "To get the key content for GitHub:"
echo "  cat $KEY_FILE"
echo "  # Copy the raw JSON content"
echo ""
echo "============================================"
echo "IMPORTANT: Delete the local key file after adding to GitHub!"
echo "  rm $KEY_FILE"
echo "============================================"