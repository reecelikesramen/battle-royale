#!/usr/bin/env bash
#
# Rewrap Godot's mac export so the launcher is the .app entry point.
#
# Input layout (from Godot 4 mac exporter):
#   build/mac/${_EXPORT_NAME}.zip
#     └── Battle Royale.app/
#           Contents/
#             Info.plist          (CFBundleExecutable=<godot game name>)
#             MacOS/
#               <godot game binary>
#             Resources/
#               *.pck, icon.icns, ...
#
# Output layout (drop-in replacement at the same zip path):
#   Battle Royale.app/
#     Contents/
#       Info.plist          (CFBundleExecutable=launcher)
#       MacOS/
#         launcher          ← new entry point (Slint UI, no Terminal)
#         launcher-updater  ← bootstrap for self-update
#         <godot binary kept under its original name>
#       Resources/...
#
# Double-click on the .app now launches the launcher; the launcher spawns
# the game binary that lives next to it inside Contents/MacOS. Gatekeeper
# approval (right-click → Open the first time) covers the whole bundle.

set -euo pipefail

: "${_EXPORT_NAME:?must be set}"

ZIP="build/mac/${_EXPORT_NAME}.zip"
LAUNCHER="launchers/mac/launcher"
UPDATER="launchers/mac/launcher-updater"

if [[ ! -f "$ZIP" ]]; then
  echo "no $ZIP; skipping mac .app rewrap"
  exit 0
fi
if [[ ! -f "$LAUNCHER" || ! -f "$UPDATER" ]]; then
  echo "WARNING: missing mac launcher binaries at $LAUNCHER / $UPDATER; skipping rewrap" >&2
  exit 0
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

unzip -qo "$ZIP" -d "$STAGE"

APP=$(find "$STAGE" -maxdepth 2 -name '*.app' -type d | head -1)
if [[ -z "$APP" ]]; then
  echo "ERROR: no .app bundle found inside $ZIP" >&2
  exit 1
fi
MACOS="$APP/Contents/MacOS"
PLIST="$APP/Contents/Info.plist"

if [[ ! -d "$MACOS" ]]; then
  echo "ERROR: $APP missing Contents/MacOS" >&2
  exit 1
fi

# Rename the Godot-exported game binary to match what the launcher looks
# for (`battle-royale`, see launcher/src/platform.rs::game_exe_name).
# Godot names the binary after the project's `application/config/name`,
# which is "Battle Royale" with a space — so without this rename, the
# launcher reports `game executable not found at .../battle-royale`.
GAME_SRC=$(find "$MACOS" -maxdepth 1 -type f \
  ! -name launcher ! -name launcher-updater ! -name battle-royale | head -1)
if [[ -z "$GAME_SRC" ]]; then
  if [[ ! -f "$MACOS/battle-royale" ]]; then
    echo "ERROR: no game binary found in $MACOS" >&2
    exit 1
  fi
else
  mv "$GAME_SRC" "$MACOS/battle-royale"
  chmod +x "$MACOS/battle-royale"
fi

install -m 0755 "$LAUNCHER" "$MACOS/launcher"
install -m 0755 "$UPDATER"  "$MACOS/launcher-updater"

# Drop build-sha.txt next to the game binary inside the .app. Runtime reads
# via OS.get_executable_path().get_base_dir(), which on macOS points at
# Contents/MacOS — same dir we install the launcher into. Optional: if the
# caller didn't pass BUILD_SHA_FILE we skip silently (local dev rewraps).
if [[ -n "${BUILD_SHA_FILE:-}" && -f "$BUILD_SHA_FILE" ]]; then
  install -m 0644 "$BUILD_SHA_FILE" "$MACOS/build-sha.txt"
fi

# Patch Info.plist: CFBundleExecutable -> launcher. PlistBuddy isn't on
# Cloud Build's Linux runners, so we use a small Python rewrite via plistlib.
python3 - "$PLIST" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f:
    pl = plistlib.load(f)
pl["CFBundleExecutable"] = "launcher"
# Keep showing a real app icon in Dock; LSUIElement false means a normal
# windowed GUI app (no menu bar, no dock icon == True; we want False).
pl["LSUIElement"] = False
with open(p, "wb") as f:
    plistlib.dump(pl, f)
PY

# Repack atomically: rebuild the zip from a clean staging dir.
rm -f "$ZIP"
(cd "$STAGE" && zip -qry "$OLDPWD/$ZIP" .)
echo "mac .app rewrapped: $(unzip -l "$ZIP" | tail -1)"
