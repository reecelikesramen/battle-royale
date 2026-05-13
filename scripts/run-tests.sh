#!/usr/bin/env bash
# Run the full netcode test suite: cargo unit tests + the headless Godot
# runner that exercises GDScript paths.
#
# Usage:
#   scripts/run-tests.sh             # both suites
#   scripts/run-tests.sh --rust      # cargo test --lib only
#   scripts/run-tests.sh --godot     # GDScript runner only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_RUST=1
RUN_GODOT=1

for arg in "$@"; do
    case "$arg" in
        --rust) RUN_GODOT=0 ;;
        --godot) RUN_RUST=0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

FAIL=0

if [ "$RUN_RUST" -eq 1 ]; then
    echo "=== cargo test --lib ==="
    # protobuf@21 is required because GNS C++ build expects the legacy
    # std::string return type from GetTypeName().
    PB21="$(brew --prefix protobuf@21 2>/dev/null || echo)"
    if [ -n "$PB21" ] && [ -d "$PB21" ]; then
        export PATH="$PB21/bin:$PATH"
        export PKG_CONFIG_PATH="$PB21/lib/pkgconfig"
        export Protobuf_DIR="$PB21/lib/cmake/protobuf"
        export CMAKE_PREFIX_PATH="$PB21"
    fi
    if ! (cd "$REPO_ROOT/rust" && cargo test --lib); then
        FAIL=1
    fi
fi

if [ "$RUN_GODOT" -eq 1 ]; then
    echo
    echo "=== godot headless test runner ==="
    GODOT_BIN="${GODOT_BIN:-}"
    if [ -z "$GODOT_BIN" ]; then
        if [ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]; then
            GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
        elif command -v godot >/dev/null 2>&1; then
            GODOT_BIN="$(command -v godot)"
        else
            echo "Godot binary not found. Set GODOT_BIN env var." >&2
            exit 2
        fi
    fi
    if ! NETCODE_TEST_MODE=1 "$GODOT_BIN" --headless \
            --path "$REPO_ROOT/godot" \
            res://tests/test_runner.tscn; then
        FAIL=1
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    echo
    echo "TESTS FAILED"
    exit 1
fi
echo
echo "ALL TESTS PASSED"
