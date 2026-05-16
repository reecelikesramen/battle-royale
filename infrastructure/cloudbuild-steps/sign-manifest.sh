#!/usr/bin/env bash
#
# Sign versions.json with the ed25519 key in Secret Manager.
# Writes versions.json.sig (64 raw signature bytes).
#
# Env in:
#   _BUCKET         — GCS bucket (informational)
#   GCP_PROJECT_ID  — for `gcloud secrets versions access`
#   SECRET_NAME     — defaults to "manifest-signing-key"

set -euo pipefail

: "${GCP_PROJECT_ID:?must be set (pass _PROJECT_ID as cloudbuild substitution)}"
SECRET_NAME="${SECRET_NAME:-manifest-signing-key}"

# Refuse to sign with the all-zero placeholder pubkey still in the repo.
# That would mean nobody has run generate-signing-key.sh yet, and signing
# would produce signatures that no real launcher can verify.
PUB_KEY_FILE="${PUB_KEY_FILE:-infrastructure/keys/manifest_pub.ed25519}"
if [[ -f "$PUB_KEY_FILE" ]]; then
  PUB_SHA=$(sha256sum "$PUB_KEY_FILE" | awk '{print $1}')
  ZERO_SHA=$(head -c 32 /dev/zero | sha256sum | awk '{print $1}')
  if [[ "$PUB_SHA" == "$ZERO_SHA" ]]; then
    echo "ERROR: $PUB_KEY_FILE is the all-zero placeholder." >&2
    echo "       Run infrastructure/keys/generate-signing-key.sh and upload the PEM to Secret Manager." >&2
    exit 1
  fi
fi

KEY_PEM=$(mktemp)
trap 'shred -u "$KEY_PEM" 2>/dev/null || rm -f "$KEY_PEM"' EXIT

gcloud --project="$GCP_PROJECT_ID" secrets versions access latest \
  --secret="$SECRET_NAME" > "$KEY_PEM"

# ed25519 is a "pure" signature scheme — sign the raw message, not a hash.
# openssl pkeyutl with -rawin handles that.
openssl pkeyutl -sign \
  -inkey "$KEY_PEM" \
  -rawin -in versions.json \
  -out versions.json.sig

SIG_BYTES=$(wc -c < versions.json.sig)
if [[ "$SIG_BYTES" -ne 64 ]]; then
  echo "ERROR: expected 64-byte ed25519 signature, got $SIG_BYTES" >&2
  exit 1
fi
echo "Signed versions.json -> versions.json.sig (64 bytes)"
