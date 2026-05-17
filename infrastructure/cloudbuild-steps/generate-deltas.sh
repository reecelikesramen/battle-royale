#!/usr/bin/env bash
#
# Build zstd `--patch-from` deltas for each binary artifact between the
# previous release and this one. Output goes to deltas/{tag}/{platform}/{component}.zpatch
# and is uploaded to GCS at gs://${_BUCKET}/deltas/{tag}/{platform}/{component}.zpatch.
#
# Env in:
#   _BUCKET, _TAG_NAME, _EXPORT_NAME, _PROJECT_NAME
#
# This step runs after exports (so the new build artifacts exist locally
# under build/) and after download-previous-pcks (which already fetches
# previous-pcks/{windows,linux,mac}-base.pck for the PCK delta path; we
# fetch the wider binary set inline below).

set -euo pipefail

: "${_BUCKET:?must be set}"
: "${_TAG_NAME:?must be set}"
: "${_EXPORT_NAME:?must be set}"
: "${_PROJECT_NAME:?must be set}"

# Identify the previous release tag (skipping this one).
prev_tag=$(gsutil ls "gs://${_BUCKET}/releases/" 2>/dev/null \
  | sed -nE 's#^gs://[^/]+/releases/(v[0-9].*)/$#\1#p' \
  | grep -v "^${_TAG_NAME}$" \
  | sort -V | tail -1)

if [[ -z "$prev_tag" ]]; then
  echo "no previous release; skipping delta generation"
  exit 0
fi

echo "Generating deltas: $prev_tag -> ${_TAG_NAME}"
mkdir -p prev/{windows,linux,linux-server,mac} deltas

# Download the previous release's full builds.
gsutil -q cp "gs://${_BUCKET}/releases/${prev_tag}/windows.zip"      prev/windows.zip      || true
gsutil -q cp "gs://${_BUCKET}/releases/${prev_tag}/linux.zip"        prev/linux.zip        || true
gsutil -q cp "gs://${_BUCKET}/releases/${prev_tag}/linux-server.zip" prev/linux-server.zip || true
gsutil -q cp "gs://${_BUCKET}/releases/${prev_tag}/mac.zip"          prev/mac.zip          || true
gsutil -q cp "gs://${_BUCKET}/rust-libs/${prev_tag}/librust.so"   prev/linux/librust.so   || true
gsutil -q cp "gs://${_BUCKET}/rust-libs/${prev_tag}/librust.dylib" prev/mac/librust.dylib || true
gsutil -q cp "gs://${_BUCKET}/rust-libs/${prev_tag}/rust.dll"     prev/windows/rust.dll   || true
gsutil -q cp "gs://${_BUCKET}/launcher/${prev_tag}/linux/launcher"               prev/linux/launcher               || true
gsutil -q cp "gs://${_BUCKET}/launcher/${prev_tag}/mac/launcher"                 prev/mac/launcher                 || true
gsutil -q cp "gs://${_BUCKET}/launcher/${prev_tag}/windows/launcher.exe"         prev/windows/launcher.exe         || true
gsutil -q cp "gs://${_BUCKET}/launcher/${prev_tag}/linux/launcher-updater"       prev/linux/launcher-updater       || true
gsutil -q cp "gs://${_BUCKET}/launcher/${prev_tag}/mac/launcher-updater"         prev/mac/launcher-updater         || true
gsutil -q cp "gs://${_BUCKET}/launcher/${prev_tag}/windows/launcher-updater.exe" prev/windows/launcher-updater.exe || true

# Unpack the prev zips so we can grab the game binaries.
for plat in windows linux linux-server; do
  if [[ -f "prev/$plat.zip" ]]; then
    (cd prev && unzip -q -o "$plat.zip")
  fi
done
if [[ -f "prev/mac.zip" ]]; then
  (cd prev && mkdir -p mac && cd mac && unzip -q -o ../mac.zip)
fi

# Helper: make a zstd delta if both files exist. zstd is invoked with
# --long=27 to match `--patch-from`'s long-range mode.
#
# -T0 fans the compressor across all available cores; on Cloud Build's
# default 2-vCPU runner this is roughly a 2× speedup. -12 trades a small
# bit of delta size (PCK is already godot-compressed so the top levels
# squeeze little) for a 3× speedup over -19. Together: pck_base deltas
# (1+ GB each, three platforms) drop from ~10 min to ~2-3 min.
make_delta() {
  local prev_file="$1"
  local new_file="$2"
  local out="$3"
  if [[ ! -f "$prev_file" || ! -f "$new_file" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  zstd -12 -T0 --long=27 --patch-from="$prev_file" "$new_file" -o "$out" \
    2>/dev/null || echo "zstd patch failed for $new_file (continuing)"
}

# Per-platform deltas.
out_root="deltas/${_TAG_NAME}"

# Windows.
make_delta prev/windows/${_EXPORT_NAME}.exe build/windows/${_EXPORT_NAME}.exe ${out_root}/windows/game_binary.zpatch
make_delta prev/windows/rust.dll            ${_PROJECT_PATH:-godot}/addons/rust/bin/rust.dll ${out_root}/windows/rust_lib.zpatch
make_delta prev/windows/launcher.exe        launchers/windows/launcher.exe ${out_root}/windows/launcher.zpatch
make_delta prev/windows/launcher-updater.exe launchers/windows/launcher-updater.exe ${out_root}/windows/launcher_updater.zpatch

# Linux.
make_delta prev/linux/${_EXPORT_NAME}.x86_64 build/linux/${_EXPORT_NAME}.x86_64 ${out_root}/linux/game_binary.zpatch
make_delta prev/linux/librust.so             ${_PROJECT_PATH:-godot}/addons/rust/bin/librust.so ${out_root}/linux/rust_lib.zpatch
make_delta prev/linux/launcher               launchers/linux/launcher ${out_root}/linux/launcher.zpatch
make_delta prev/linux/launcher-updater       launchers/linux/launcher-updater ${out_root}/linux/launcher_updater.zpatch

# Linux dedicated server. Embedded-pck single-binary build — only the
# `game_binary` component changes between releases; `rust_lib` /
# `launcher` / `launcher_updater` reuse the client linux entries in the
# manifest (same bytes), and there is no `pck_base` to delta.
make_delta prev/linux-server/${_EXPORT_NAME}.x86_64 build/linux-server/${_EXPORT_NAME}.x86_64 ${out_root}/linux-server/game_binary.zpatch

# macOS. The game binary lives inside the .app bundle.
NEW_MAC_BIN="build/mac/${_PROJECT_NAME}.app/Contents/MacOS/${_PROJECT_NAME}"
PREV_MAC_BIN="prev/mac/${_PROJECT_NAME}.app/Contents/MacOS/${_PROJECT_NAME}"
make_delta "$PREV_MAC_BIN" "$NEW_MAC_BIN"   ${out_root}/mac/game_binary.zpatch
make_delta prev/mac/librust.dylib           ${_PROJECT_PATH:-godot}/addons/rust/bin/librust.dylib ${out_root}/mac/rust_lib.zpatch
make_delta prev/mac/launcher                launchers/mac/launcher ${out_root}/mac/launcher.zpatch
make_delta prev/mac/launcher-updater        launchers/mac/launcher-updater ${out_root}/mac/launcher_updater.zpatch

# pck_base deltas — the dominant payload (1+GB each). Previous bases come from
# download-previous-pcks at previous-pcks/{platform}-base.pck. The current
# bases live in release/ at this point (zip-builds has already mv'd them out
# of build/{platform}/), so we read from there. Per-tag patch is applied by
# the launcher via apply_zstd_patch before spawning the game, so the user
# only downloads the diff (typically tens of MB).
make_delta previous-pcks/windows-base.pck release/windows-base.pck ${out_root}/windows/pck_base.zpatch
make_delta previous-pcks/linux-base.pck   release/linux-base.pck   ${out_root}/linux/pck_base.zpatch
make_delta previous-pcks/mac-base.pck     release/mac-base.pck     ${out_root}/mac/pck_base.zpatch

# Upload all deltas.
if compgen -G "deltas/${_TAG_NAME}/*/*.zpatch" > /dev/null; then
  gsutil -m cp -r "deltas/${_TAG_NAME}" "gs://${_BUCKET}/deltas/"
  echo "Deltas uploaded:"
  find "deltas/${_TAG_NAME}" -type f -name '*.zpatch' -exec ls -lh {} \;
else
  echo "no deltas produced (likely missing prev files); skipping upload"
fi
