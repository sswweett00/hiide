#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Setting up Flutter desktop support..."
cd "$PROJECT_ROOT/flutter_app"

if [ ! -d "linux" ] || [ ! -d "windows" ] || [ ! -d "macos" ]; then
    flutter create .
else
    echo "Desktop folders already exist. Skipping flutter create."
fi

echo "Flutter desktop setup complete."
