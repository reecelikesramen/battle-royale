#!/usr/bin/env bash
# Bundle godot/addons/netcode/ into a distributable addon by copying the
# Rust release binary into bin/ with the platform-suffixed name the template
# .gdextension expects, then materializing the .gdextension from the template.
#
# Usage:
#   scripts/make-addon.sh                 # builds + copies for host platform
#   scripts/make-addon.sh --skip-build    # use existing rust/target/release
#
# CI builds the three platforms in parallel and runs this script in --skip-build
# mode after dropping the cross-built libs into rust/target/release/<triple>/.
# Right now only host-platform packaging is wired up; cross-platform plumbing
# lands when CI is updated.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$REPO_ROOT/rust"
ADDON_DIR="$REPO_ROOT/godot/addons/netcode"
BIN_DIR="$ADDON_DIR/bin"
TEMPLATE="$ADDON_DIR/netcode.gdextension.template"
GDEXT_OUT="$ADDON_DIR/netcode.gdextension"

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
HOST_ARCH="$(uname -m)"

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

echo "==> render $GDEXT_OUT from template"
cp "$TEMPLATE" "$GDEXT_OUT"

echo "done. Distribute: $ADDON_DIR"
