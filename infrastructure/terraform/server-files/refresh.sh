#!/usr/bin/env bash
#
# Runs as the first ExecStartPre for the game server. Bootstrap-only:
# downloads + unpacks linux-server.zip with manifest signature verification
# when the game binary is missing (fresh VM, blown install dir, etc.). On
# a healthy install, short-circuits to no-op — the second ExecStartPre
# (launcher --update-only --server) does incremental delta updates.
#
# linux-server.zip carries the stripped dedicated-server build (embedded
# pck, textures/audio stripped) at ~50-150 MB — vastly faster + less
# memory-hungry to install than the 1+ GB client linux.zip we used to
# pull here, which trapped the server in OOM-kill loops on the pck delta
# apply path. The client variant is still produced and uploaded under
# `releases/{tag}/linux.zip` for actual clients.

set -euo pipefail

INSTALL=/opt/battle-royale
GAME_BIN="$INSTALL/battle-royale.x86_64"
META_FILE=/etc/battle-royale/meta.env
BUCKET="$(awk -F= '/^BUCKET=/ {print $2}' "$META_FILE")"

cd "$INSTALL"

if [[ -x "$GAME_BIN" ]]; then
  echo "refresh.sh: bootstrap already complete; skipping full zip pull"
  exit 0
fi

echo "refresh.sh: no game binary on disk — running bootstrap install"

# Fetch manifest to a file (NOT via command substitution, which strips
# trailing newlines and breaks the signature, since the signer signs the
# raw bytes including any trailing \n that the manifest generator emits).
MANIFEST_FILE=$(mktemp)
PUB_PEM=$(mktemp)
trap 'rm -f "$PUB_PEM" "$MANIFEST_FILE" /tmp/manifest.sig' EXIT

curl -fsSL "https://storage.googleapis.com/${BUCKET}/versions.json?t=$(date +%s)" \
  -o "$MANIFEST_FILE"
sig=$(curl -fsSL "https://storage.googleapis.com/${BUCKET}/versions.json.sig?t=$(date +%s)" \
  --output /tmp/manifest.sig --write-out '%{http_code}')
[[ "$sig" == "200" ]] || { echo "sig fetch failed: $sig" >&2; exit 1; }

# Verify ed25519 signature using the public key baked at install time.
PUB_RAW=/etc/battle-royale/manifest_pub.ed25519
# Convert raw 32-byte pubkey to PEM SubjectPublicKeyInfo for openssl pkeyutl.
{
  printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
  cat "$PUB_RAW"
} | openssl pkey -pubin -inform DER -pubout -outform PEM > "$PUB_PEM"

if ! openssl pkeyutl -verify -pubin -inkey "$PUB_PEM" -rawin -in "$MANIFEST_FILE" -sigfile /tmp/manifest.sig; then
  echo "manifest signature verify FAILED — refusing to bootstrap" >&2
  exit 1
fi

latest=$(jq -r '.latest' "$MANIFEST_FILE")
echo "refresh.sh: bootstrapping $latest"

# Pull the dedicated-server release zip and unpack everything. The zip
# carries the embedded-pck server binary, rust_lib, launcher,
# launcher-updater, build-sha.txt, VERSION.txt — no separate pck file,
# because the server binary embeds the stripped pck. After this, the
# launcher's `--update-only --server` pass owns incremental updates
# against the `linux-server` manifest platform entry.
URL="https://storage.googleapis.com/${BUCKET}/releases/${latest}/linux-server.zip"
STAGING=$(mktemp -d); trap 'rm -rf "$STAGING" "$PUB_PEM" "$MANIFEST_FILE" /tmp/manifest.sig' EXIT
curl -fsSL "$URL" -o "$STAGING/linux-server.zip"

unzip -qo "$STAGING/linux-server.zip" -d "$STAGING"
# The zip contains `linux-server/{battle-royale.x86_64, librust.so, launcher, ...}`.
install -m 0755 -D -t "$INSTALL" "$STAGING"/linux-server/*
echo "$latest" > "$INSTALL/VERSION.txt"
chown -R gameserver:gameserver "$INSTALL"
echo "refresh.sh: bootstrap complete (installed $latest)"
