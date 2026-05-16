#!/usr/bin/env bash
#
# Runs as ExecStartPre for the game server. Fetches the current
# versions-v2.json, verifies its ed25519 signature, downloads the latest
# Linux dedicated-server build if not already on disk, and unpacks it
# into /opt/battle-royale/.
#
# Idempotent: if the installed version already matches manifest.latest,
# this is a fast no-op (one HTTPS GET).

set -euo pipefail

INSTALL=/opt/battle-royale
META_FILE=/etc/battle-royale/meta.env
BUCKET="$(awk -F= '/^BUCKET=/ {print $2}' "$META_FILE")"

cd "$INSTALL"

manifest=$(curl -fsSL "https://storage.googleapis.com/${BUCKET}/versions-v2.json?t=$(date +%s)")
sig=$(curl -fsSL "https://storage.googleapis.com/${BUCKET}/versions-v2.json.sig?t=$(date +%s)" \
  --output /tmp/manifest.sig --write-out '%{http_code}')
[[ "$sig" == "200" ]] || { echo "sig fetch failed: $sig" >&2; exit 1; }

# Verify ed25519 signature using the public key baked at install time.
PUB_RAW=/etc/battle-royale/manifest_pub.ed25519
# Convert raw 32-byte pubkey to PEM SubjectPublicKeyInfo for openssl pkeyutl.
PUB_PEM=$(mktemp); trap 'rm -f "$PUB_PEM"' EXIT
{
  printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
  cat "$PUB_RAW"
} | openssl pkey -pubin -inform DER -pubout -outform PEM > "$PUB_PEM"

MANIFEST_FILE=$(mktemp); trap 'rm -f "$PUB_PEM" "$MANIFEST_FILE" /tmp/manifest.sig' EXIT
printf '%s' "$manifest" > "$MANIFEST_FILE"

if ! openssl pkeyutl -verify -pubin -inkey "$PUB_PEM" -rawin -in "$MANIFEST_FILE" -sigfile /tmp/manifest.sig; then
  echo "manifest signature verify FAILED — refusing to update" >&2
  exit 1
fi

latest=$(jq -r '.latest' "$MANIFEST_FILE")
current=$(cat "$INSTALL/VERSION.txt" 2>/dev/null || echo "v0.0.0")

if [[ "$latest" == "$current" ]]; then
  echo "Server already on $latest"
  exit 0
fi

echo "Refreshing $current -> $latest"

# Download the linux release zip and unpack. We use the linux dedicated-server
# build (same binary, just runs with --server).
URL=$(jq -r --arg p linux '.versions[.latest].platforms[$p].game_binary.url' "$MANIFEST_FILE")
SHA=$(jq -r --arg p linux '.versions[.latest].platforms[$p].game_binary.sha256' "$MANIFEST_FILE")

STAGING=$(mktemp -d); trap 'rm -rf "$STAGING" "$PUB_PEM" "$MANIFEST_FILE" /tmp/manifest.sig' EXIT
curl -fsSL "$URL" -o "$STAGING/linux.zip"
got=$(sha256sum "$STAGING/linux.zip" | awk '{print $1}')
if [[ "$got" != "$SHA" ]]; then
  echo "sha256 mismatch on game_binary: expected $SHA got $got" >&2
  exit 1
fi

unzip -qo "$STAGING/linux.zip" -d "$STAGING"
# The zip contains `linux/{battle-royale.x86_64, *.pck, *.so, ...}`.
install -m 0755 -D -t "$INSTALL" "$STAGING"/linux/*
echo "$latest" > "$INSTALL/VERSION.txt"
chown -R gameserver:gameserver "$INSTALL"
echo "Updated to $latest"
