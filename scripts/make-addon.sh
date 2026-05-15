#!/usr/bin/env bash
# Bundle godot/addons/netcode/ into a distributable copy of the addon. The
# in-tree addons/netcode/netcode.gdextension uses mixed dev paths (debug ->
# rust/target/debug/, release -> addons/netcode/bin/) so editor + release
# builds both work locally; for shipping, this script copies the addon to
# dist/netcode-addon/ and renders netcode.gdextension.template into the
# dist's .gdextension — distribution paths target only addons/netcode/bin/.
#
# Usage:
#   scripts/make-addon.sh                 # builds + copies for host platform
#   scripts/make-addon.sh --skip-build    # use existing rust/target/release
#
# CI invokes this with --skip-build after gathering the three cross-built
# libs into addons/netcode/bin/ from artifact uploads.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust"
ADDON_DIR="$REPO_ROOT/godot/addons/netcode"
BIN_DIR="$ADDON_DIR/bin"
TEMPLATE="$ADDON_DIR/netcode.gdextension.template"
DIST_DIR="$REPO_ROOT/dist/netcode-addon"

SKIP_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$BIN_DIR"

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "==> cargo build --release"
    (cd "$RUST_DIR" && cargo build --release)
fi

HOST_OS="$(uname -s)"

case "$HOST_OS" in
    Darwin)
        SRC="$RUST_DIR/target/release/librust.dylib"
        DST="$BIN_DIR/libnetcode.macos.universal.dylib"
        ;;
    Linux)
        SRC="$RUST_DIR/target/release/librust.so"
        DST="$BIN_DIR/libnetcode.linux.x86_64.so"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        SRC="$RUST_DIR/target/release/rust.dll"
        DST="$BIN_DIR/libnetcode.windows.x86_64.dll"
        ;;
    *)
        echo "unsupported host OS: $HOST_OS" >&2
        exit 2
        ;;
esac

if [ ! -f "$SRC" ]; then
    echo "missing release binary at $SRC; build first or pass --skip-build only if files exist" >&2
    exit 1
fi

echo "==> copy $SRC -> $DST"
cp "$SRC" "$DST"

echo "==> assemble dist tree at $DIST_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
# Replicate the addon dir but swap the dev .gdextension for the rendered
# distribution one. .uid sidecar files come along so cross-scene refs stay
# valid in the target project.
(cd "$ADDON_DIR" && tar --exclude netcode.gdextension --exclude netcode.gdextension.template -cf - .) | (cd "$DIST_DIR" && tar -xf -)
cp "$TEMPLATE" "$DIST_DIR/netcode.gdextension"

echo "done. Distribute: $DIST_DIR"
