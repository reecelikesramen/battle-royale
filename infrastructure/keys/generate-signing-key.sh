#!/usr/bin/env bash
#
# Generate a fresh ed25519 keypair for signing the release manifest.
# - Writes the 32-byte raw public key to ./manifest_pub.ed25519 (committed)
# - Prints the PEM-formatted private key to stdout
# - Prints the exact gcloud command to upload that PEM to Secret Manager
#
# The private key is NEVER written to disk by this script. Pipe stdout to
# the gcloud command or paste it carefully — and close your terminal scrollback
# afterwards.
#
# Requires: openssl >= 1.1.1 (for ed25519 support).

set -euo pipefail

cd "$(dirname "$0")"

if ! openssl version | grep -qE '^OpenSSL ([1-9]\.[1-9])'; then
  echo "openssl 1.1+ required for ed25519. Install via 'brew install openssl' or apt." >&2
  exit 1
fi

PROJECT_ID="${PROJECT_ID:-erudite-cycle-480104}"
SECRET_NAME="${SECRET_NAME:-manifest-signing-key}"

PRIV_PEM="$(openssl genpkey -algorithm ed25519)"

PUB_DER="$(mktemp)"
trap 'rm -f "$PUB_DER"' EXIT
echo "$PRIV_PEM" | openssl pkey -pubout -outform DER -out "$PUB_DER"
# A DER-encoded ed25519 SubjectPublicKeyInfo is 44 bytes; the last 32 are the
# raw public key. Strip the 12-byte prefix.
tail -c 32 "$PUB_DER" > manifest_pub.ed25519
chmod 644 manifest_pub.ed25519

cat <<EOF
============================================================
Public key written to: infrastructure/keys/manifest_pub.ed25519
  size: $(wc -c < manifest_pub.ed25519) bytes (expect 32)
  sha256: $(shasum -a 256 manifest_pub.ed25519 | awk '{print $1}')

Commit this file:
  git add infrastructure/keys/manifest_pub.ed25519

============================================================
Private key (PEM) — upload to Secret Manager NOW and then forget:

$PRIV_PEM

============================================================
Recommended command (paste the PEM into stdin):

  gcloud --project=$PROJECT_ID secrets versions add $SECRET_NAME --data-file=-

The Secret Manager *resource* is managed by Terraform (see
infrastructure/terraform/secrets.tf). Run \`terraform apply\` before this
script if you haven't yet. If you ever see a "secret not found" error here,
that means Terraform hasn't been applied.

============================================================
Close your terminal scrollback once the PEM is in Secret Manager.
EOF
