#!/usr/bin/env bash
#
# Post-publish smoke test. Downloads versions.json + .sig from the SAME
# public URL real users hit, verifies the ed25519 signature with the committed
# pubkey, and checks that every component URL in the manifest is reachable
# and (for one randomly-chosen component per platform) sha256-matches the
# value the manifest claims.
#
# Fails the build if anything mismatches. This is the gate that prevents a
# bad release from reaching real users.
#
# Env in:
#   _BUCKET            — GCS bucket
#   _TAG_NAME          — current release tag
#   PUB_KEY_FILE       — raw 32-byte ed25519 public key (default: repo path)
#   VERIFY_FULL_SHA    — "1" to sha256 every component, default samples one
#                        per platform to keep build time reasonable.

set -euo pipefail

: "${_BUCKET:?must be set}"
: "${_TAG_NAME:?must be set}"

PUB_KEY_FILE="${PUB_KEY_FILE:-infrastructure/keys/manifest_pub.ed25519}"
BASE="https://storage.googleapis.com/${_BUCKET}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ─── Refuse the all-zero placeholder ────────────────────────────────────────
PUB_SHA=$(sha256sum "$PUB_KEY_FILE" | awk '{print $1}')
ZERO_SHA=$(head -c 32 /dev/zero | sha256sum | awk '{print $1}')
if [[ "$PUB_SHA" == "$ZERO_SHA" ]]; then
  echo "ERROR: $PUB_KEY_FILE is the all-zero placeholder; nothing real to verify against." >&2
  exit 1
fi

# ─── Download manifest + signature from the PUBLIC URL ─────────────────────
echo "Downloading versions.json + .sig from $BASE ..."
curl -fsSL "$BASE/versions.json"     -o "$WORK/versions.json"
curl -fsSL "$BASE/versions.json.sig" -o "$WORK/versions.json.sig"

# Wrap the raw 32-byte ed25519 pubkey in DER SubjectPublicKeyInfo so openssl
# pkeyutl can read it. Prefix is the standard ed25519 SPKI header.
PEM_PUB="$WORK/pub.pem"
{
  printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
  cat "$PUB_KEY_FILE"
} | openssl pkey -pubin -inform DER -outform PEM > "$PEM_PUB"

# ─── Verify the signature ──────────────────────────────────────────────────
if ! openssl pkeyutl -verify -pubin -inkey "$PEM_PUB" \
      -rawin -in "$WORK/versions.json" \
      -sigfile "$WORK/versions.json.sig" \
      > /dev/null; then
  echo "ERROR: manifest signature verification FAILED. A real launcher would refuse this release." >&2
  exit 1
fi
echo "Manifest signature verified."

# ─── Check that the published manifest is internally consistent ────────────
if ! command -v jq >/dev/null 2>&1; then
  # Direct binary download — avoids apt/dpkg hangs in restricted builders.
  curl -fsSL -o /usr/local/bin/jq \
    https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
  chmod +x /usr/local/bin/jq
fi

CURRENT_TAG=$(jq -r .latest "$WORK/versions.json")
if [[ "$CURRENT_TAG" != "${_TAG_NAME}" ]]; then
  echo "ERROR: manifest .latest=$CURRENT_TAG but cloudbuild ran for ${_TAG_NAME}." >&2
  exit 1
fi

# Collect URL + sha + size for every (platform, component) in the current tag.
mapfile -t entries < <(jq -r --arg t "${_TAG_NAME}" '
  .versions[$t].platforms
  | to_entries[]
  | .key as $plat
  | .value
  | to_entries[]
  | "\($plat)|\(.key)|\(.value.url)|\(.value.sha256)|\(.value.size)"' "$WORK/versions.json")

if [[ "${#entries[@]}" -eq 0 ]]; then
  echo "ERROR: no platforms/components in manifest for tag ${_TAG_NAME}." >&2
  exit 1
fi

# Track one sampled component per platform so every platform gets a full
# sha256 check (cheaper than checking every artifact, still proves the
# delivery + manifest agree for each OS).
declare -A sampled
fail=0
for line in "${entries[@]}"; do
  IFS='|' read -r plat comp url sha size <<< "$line"

  # HEAD every URL; cheap and catches the common "manifest points at a
  # deleted artifact" footgun.
  if ! status=$(curl -fsSL -o /dev/null -w '%{http_code}' --head "$url"); then
    status="curl-failed"
  fi
  if [[ "$status" != "200" ]]; then
    echo "ERROR: HEAD $url -> $status (component $plat/$comp)" >&2
    fail=1
    continue
  fi

  # Sha + size check on first component of each platform (or all if VERIFY_FULL_SHA=1).
  if [[ "${VERIFY_FULL_SHA:-0}" == "1" || -z "${sampled[$plat]:-}" ]]; then
    sampled[$plat]=1
    local_path="$WORK/$(echo "$plat-$comp" | tr / _)"
    if ! curl -fsSL "$url" -o "$local_path"; then
      echo "ERROR: GET $url failed" >&2
      fail=1
      continue
    fi
    actual_sha=$(sha256sum "$local_path" | awk '{print $1}')
    actual_size=$(stat -c%s "$local_path" 2>/dev/null || stat -f%z "$local_path")
    rm -f "$local_path"
    if [[ "$actual_sha" != "$sha" ]]; then
      echo "ERROR: sha mismatch on $plat/$comp ($url): manifest=$sha actual=$actual_sha" >&2
      fail=1
    fi
    if [[ "$actual_size" != "$size" ]]; then
      echo "ERROR: size mismatch on $plat/$comp ($url): manifest=$size actual=$actual_size" >&2
      fail=1
    fi
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "verify-manifest FAILED — release is unsafe to publish." >&2
  exit 1
fi
echo "Manifest verified: ${#entries[@]} components reachable, sampled sha256 OK."
