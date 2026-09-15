#!/usr/bin/env bash
set -euo pipefail

export FLUTTER_ROOT="/home/kaan/projeler/hiide/flutter_app/writable_flutter"
FLUTTER_TOOLS_DIR="/home/kaan/development/flutter/packages/flutter_tools"
SNAPSHOT="/home/kaan/development/flutter/bin/cache/flutter_tools.snapshot"
DART_SDK="/home/kaan/development/flutter/bin/cache/dart-sdk"

mkdir -p "$FLUTTER_ROOT/bin/cache"
echo "0cd610717bde95fd88343c64f81c11ba4e5c0010" > "$FLUTTER_ROOT/bin/cache/engine.stamp"
echo "" > "$FLUTTER_ROOT/bin/cache/engine.realm"
touch "$FLUTTER_ROOT/bin/cache/lockfile"
echo '{"build_time_ms":1724457600000,"git_revision":"0cd610717bde95fd88343c64f81c11ba4e5c0010","git_revision_date":"2024-08-24T00:00:00.000Z","content_hash":"0cd610717bde95fd88343c64f81c11ba4e5c0010"}' > "$FLUTTER_ROOT/bin/cache/engine_stamp.json"
echo "0cd610717bde" > "$FLUTTER_ROOT/version"

exec "$DART_SDK/bin/dart" \
  --packages="$FLUTTER_TOOLS_DIR/.dart_tool/package_config.json" \
  "$SNAPSHOT" \
  "$@"
