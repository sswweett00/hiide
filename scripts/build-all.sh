#!/usr/bin/env bash
# ── hiide: build all available layers ────────────────────────────────────────
# Builds every component that is present in the repo:
#
#   1. Zig engine   → static lib (zig-out/lib) + all executables (zig-out/bin)
#   2. Flutter IDE  → the active UI (flutter_app/)
#
# The Tauri desktop shell (apps/) and the Hiditor Rust editor (frontend/) are
# described in the README but their directories do not exist in this checkout.
# If you add them, uncomment the relevant sections below.
set -euo pipefail
cd "$(dirname "$0")/.."

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$(pwd)/.zig-global-cache}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

echo "==> [1/2] Building Zig engine (static lib + all executables)"
zig build
zig build test
echo "    Engine built: $(ls zig-out/bin/ 2>/dev/null | tr '\n' ' ')"

echo "==> [2/2] Building Flutter IDE"
( cd flutter_app && flutter pub get && flutter build linux )

echo
echo "All available layers built."
echo "  • Zig engine:   zig-out/bin/  (hiide-ipc-server, hiide-engine-dev, …)"
echo "  • Flutter IDE:  flutter_app/build/linux/"
echo
echo "To run the full stack:"
echo "  scripts/dev.sh"

# ── Tauri desktop shell (apps/desktop/) ──────────────────────────────────────
# Uncomment once the apps/ directory is present.
#
# echo "==> [3] Desktop shell (Tauri) — links the Zig engine"
# if ( cd apps/desktop && npx tauri build --features zig-engine ); then
#   echo "Tauri desktop built."
# else
#   echo "NOTE: the full Tauri build needs network access to fetch crates."
#   echo "      Run manually once online:"
#   echo "        cd apps/desktop && npx tauri dev --features zig-engine"
# fi

# ── Hiditor native editor (frontend/hiditor/) ─────────────────────────────────
# Uncomment once the frontend/ directory is present.
#
# echo "==> [4] Hiditor native editor (Rust + egui)"
# ( cd frontend/hiditor && cargo build --features zig-engine )
