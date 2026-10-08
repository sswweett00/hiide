#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

: "${ZIG_GLOBAL_CACHE_DIR:=$ROOT/.zig-global-cache}"
export ZIG_GLOBAL_CACHE_DIR

PACKAGE_VERSION="${HIIDE_VERSION:-}"
if [[ -z "$PACKAGE_VERSION" ]]; then
  PACKAGE_VERSION="$(sed -n "s/^version: \([^+[:space:]]*\).*/\1/p" "$ROOT/flutter_app/pubspec.yaml" | head -n 1)"
fi
PACKAGE_VERSION="${PACKAGE_VERSION#v}"
if [[ -z "$PACKAGE_VERSION" ]]; then
  echo "Unable to determine Hiide version." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64)
    DEB_ARCH="amd64"
    APPIMAGE_ARCH="x86_64"
    APPIMAGE_TOOL_ASSET="appimagetool-x86_64.AppImage"
    ;;
  aarch64|arm64)
    DEB_ARCH="arm64"
    APPIMAGE_ARCH="aarch64"
    APPIMAGE_TOOL_ASSET="appimagetool-aarch64.AppImage"
    ;;
  *)
    echo "Unsupported Linux architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

DIST_DIR="$ROOT/dist"
WORK_DIR="$DIST_DIR/work"
BUNDLE_DIR=""

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$WORK_DIR"

echo "==> Building Zig engine"
zig build -Doptimize=ReleaseSafe --summary all

test -x "$ROOT/zig-out/bin/hiide-ipc-server"

echo "==> Restoring Flutter packages"
(
  cd "$ROOT/flutter_app"
  flutter pub get
)

echo "==> Cleaning previous Flutter Linux bundle"
rm -rf "$ROOT/flutter_app/build/linux"

echo "==> Building Flutter Linux release bundle"
(
  cd "$ROOT/flutter_app"
  flutter build linux --release --build-name="$PACKAGE_VERSION"
)

while IFS= read -r candidate; do
  BUNDLE_DIR="$candidate"
  break
done < <(find "$ROOT/flutter_app/build/linux" -type d -path "*/release/bundle" -print | sort)

if [[ -z "$BUNDLE_DIR" ]]; then
  echo "Flutter Linux release bundle was not found." >&2
  exit 1
fi

test -x "$BUNDLE_DIR/hiide_flutter"
test -f "$BUNDLE_DIR/data/flutter_assets/AssetManifest.bin"

echo "==> Embedding the native Hiide engine"
install -m 0755 "$ROOT/zig-out/bin/hiide-ipc-server" "$BUNDLE_DIR/hiide-ipc-server"
test -x "$BUNDLE_DIR/hiide-ipc-server"

validate_bundle() {
  local root="$1"
  test -x "$root/usr/lib/hiide/hiide_flutter"
  test -x "$root/usr/lib/hiide/hiide-ipc-server"
  test -f "$root/usr/lib/hiide/data/flutter_assets/AssetManifest.bin"
  test -f "$root/usr/share/applications/hiide.desktop"
  test -f "$root/usr/share/metainfo/com.hiide.ide.appdata.xml"
  test -f "$root/usr/share/icons/hicolor/scalable/apps/hiide.svg"
}

echo "==> Building Debian package"
DEB_ROOT="$WORK_DIR/deb-root"
mkdir -p \
  "$DEB_ROOT/DEBIAN" \
  "$DEB_ROOT/usr/lib/hiide" \
  "$DEB_ROOT/usr/bin" \
  "$DEB_ROOT/usr/share/applications" \
  "$DEB_ROOT/usr/share/metainfo" \
  "$DEB_ROOT/usr/share/icons/hicolor/scalable/apps"

cp -a "$BUNDLE_DIR/." "$DEB_ROOT/usr/lib/hiide/"
ln -sf /usr/lib/hiide/hiide_flutter "$DEB_ROOT/usr/bin/hiide"
install -m 0644 packaging/linux/hiide.desktop \
  "$DEB_ROOT/usr/share/applications/hiide.desktop"
install -m 0644 packaging/linux/com.hiide.ide.appdata.xml \
  "$DEB_ROOT/usr/share/metainfo/com.hiide.ide.appdata.xml"
install -m 0644 packaging/linux/hiide.svg \
  "$DEB_ROOT/usr/share/icons/hicolor/scalable/apps/hiide.svg"

cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: hiide
Version: $PACKAGE_VERSION
Section: devel
Priority: optional
Architecture: $DEB_ARCH
Maintainer: Hiide Project <noreply@hiide.local>
Description: Agent-native software development workspace
 Hiide is an AI-native desktop development workspace with a local Zig engine,
 agent tools, an integrated editor and BYOK AI provider support.
Depends: libc6, libstdc++6, libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64
EOF

cat > "$DEB_ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$DEB_ROOT/DEBIAN/postinst"

validate_bundle "$DEB_ROOT"

DEB_PATH="$DIST_DIR/hiide_${PACKAGE_VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB_PATH"

echo "==> Building AppImage"
APPDIR="$WORK_DIR/Hiide.AppDir"
mkdir -p \
  "$APPDIR/usr/lib/hiide" \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/metainfo" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps"

cp -a "$BUNDLE_DIR/." "$APPDIR/usr/lib/hiide/"
ln -sf ../lib/hiide/hiide_flutter "$APPDIR/usr/bin/hiide"
install -m 0755 packaging/linux/AppRun "$APPDIR/AppRun"
install -m 0644 packaging/linux/hiide.desktop "$APPDIR/hiide.desktop"
install -m 0644 packaging/linux/hiide.svg "$APPDIR/hiide.svg"
install -m 0644 packaging/linux/hiide.desktop \
  "$APPDIR/usr/share/applications/hiide.desktop"
install -m 0644 packaging/linux/com.hiide.ide.appdata.xml \
  "$APPDIR/usr/share/metainfo/com.hiide.ide.appdata.xml"
install -m 0644 packaging/linux/hiide.svg \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps/hiide.svg"

validate_bundle "$APPDIR"

APPIMAGETOOL="${APPIMAGETOOL:-$WORK_DIR/$APPIMAGE_TOOL_ASSET}"
if [[ ! -x "$APPIMAGETOOL" ]]; then
  echo "==> Downloading official appimagetool ($APPIMAGE_ARCH)"
  curl -fL --retry 3 --retry-delay 2 \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/$APPIMAGE_TOOL_ASSET" \
    -o "$APPIMAGETOOL"
  chmod 0755 "$APPIMAGETOOL"
fi

APPIMAGE_PATH="$DIST_DIR/Hiide-${PACKAGE_VERSION}-${APPIMAGE_ARCH}.AppImage"
(
  cd "$WORK_DIR"
  ARCH="$APPIMAGE_ARCH" VERSION="$PACKAGE_VERSION" \
    "$APPIMAGETOOL" --appimage-extract-and-run \
    "$APPDIR" "$APPIMAGE_PATH"
)

test -s "$APPIMAGE_PATH"
chmod 0755 "$APPIMAGE_PATH"

echo "==> Package verification"
dpkg-deb --info "$DEB_PATH" >/dev/null
dpkg-deb --contents "$DEB_PATH" | grep -F "usr/lib/hiide/hiide-ipc-server" >/dev/null
dpkg-deb --contents "$DEB_PATH" | grep -F "usr/bin/hiide" >/dev/null
file "$DEB_PATH" "$APPIMAGE_PATH"

echo
echo "Created:"
echo "  $DEB_PATH"
echo "  $APPIMAGE_PATH"
