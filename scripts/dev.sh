#!/usr/bin/env bash
# ── hiide: run the full desktop stack ─────────────────────────────────────────
#   1. Builds the Zig engine (agent framework + workspace/IPC runtime + C ABI)
#   2. Starts the hiide-ipc-server on 127.0.0.1:4879
#   3. Runs the Flutter IDE, which connects to the engine automatically
#
# The production Flutter app requires the native engine. Test-only mocks live
# under flutter_app/test and are not used by the desktop application.
set -euo pipefail
cd "$(dirname "$0")/.."

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$(pwd)/.zig-global-cache}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

echo "==> [1/3] Building Zig engine"
zig build
zig build test

echo "==> [2/3] Starting hiide-ipc-server on 127.0.0.1:4879"
if ss -ltn 2>/dev/null | grep -q ':4879 '; then
    echo "    A server is already listening on 4879 — reusing it."
else
    ./zig-out/bin/hiide-ipc-server &
    SERVER_PID=$!
    trap 'kill "$SERVER_PID" 2>/dev/null' EXIT
    sleep 1
    if ! ss -ltn 2>/dev/null | grep -q ':4879 '; then
        echo "    ERROR: server did not start. Check the log above." >&2
        exit 1
    fi
fi

echo "==> [3/3] Launching Flutter IDE"
cd flutter_app
# Use the user's default `flutter` (or a wrapper like ./run_flutter.sh).
exec flutter run "$@"
