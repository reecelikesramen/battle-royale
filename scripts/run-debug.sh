#!/usr/bin/env bash
# Launch 1 headless server + N client GUI instances against the project.
# Mirrors the previous "F5 launches three windows" editor debug workflow.
#
# Usage:
#   scripts/run-debug.sh                  # 1 server + 2 clients (default)
#   scripts/run-debug.sh --clients 3      # 1 server + 3 clients
#   scripts/run-debug.sh --no-server      # just clients (server already running)
#   scripts/run-debug.sh --ip 192.168.1.5 # connect clients to a remote server
#   scripts/run-debug.sh --port 45900     # non-default port
#
# Ctrl+C tears down every spawned process. Per-instance logs go to /tmp/.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/godot"

CLIENTS=2
SPAWN_SERVER=1
IP="127.0.0.1"
PORT=45876

while [ $# -gt 0 ]; do
    case "$1" in
        --clients) CLIENTS="$2"; shift 2 ;;
        --no-server) SPAWN_SERVER=0; shift ;;
        --ip) IP="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

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

PIDS=()
LOGS=()
cleanup() {
    echo
    echo "Stopping spawned instances..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ "$SPAWN_SERVER" -eq 1 ]; then
    SERVER_LOG="/tmp/netcode-server.log"
    echo "[server] launching headless on port $PORT -> $SERVER_LOG"
    "$GODOT_BIN" --headless --path "$PROJECT" >"$SERVER_LOG" 2>&1 &
    PIDS+=($!)
    LOGS+=("server: $SERVER_LOG")
    # Brief beat so the GNS socket is up before clients start dialing.
    sleep 2
fi

for i in $(seq 1 "$CLIENTS"); do
    CLIENT_LOG="/tmp/netcode-client-$i.log"
    echo "[client $i] launching -> $CLIENT_LOG"
    # Stagger window positions so they don't stack exactly on top of each
    # other; tweak if your display layout differs.
    POS_X=$(( (i - 1) * 720 ))
    "$GODOT_BIN" \
        --path "$PROJECT" \
        --position "${POS_X},0" \
        -- --client "$IP" "$PORT" "Client$i" \
        >"$CLIENT_LOG" 2>&1 &
    PIDS+=($!)
    LOGS+=("client $i: $CLIENT_LOG")
    # Tiny pause so simultaneous-launch races on the .godot cache don't bite.
    sleep 0.4
done

echo
echo "Live logs:"
for entry in "${LOGS[@]}"; do
    echo "  $entry"
done
echo
echo "Ctrl+C to stop all instances."
wait
