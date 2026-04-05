#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release"
DIST_DIR="$PROJECT_DIR/dist"
DMG_ROOT="$DIST_DIR/dmg-root"
APP_NAME="ZipMate.app"
APP_DIR="$DIST_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_TEMPLATE="$PROJECT_DIR/Packaging/Info.plist"
ICON_FILE="$PROJECT_DIR/Packaging/ZipMate.icns"
EXECUTABLE="$BUILD_DIR/ZipMate"
RESOURCE_BUNDLE="$BUILD_DIR/SevenZipMacUI_SevenZipMacUI.bundle/Resources"
DMG_PATH="$DIST_DIR/ZipMate.dmg"
SKIP_BUILD="${SKIP_BUILD:-0}"

rm -rf "$APP_DIR" "$DMG_ROOT" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [[ "$SKIP_BUILD" != "1" ]]; then
  swift build -c release
fi

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "Release executable is missing at: $EXECUTABLE" >&2
  exit 1
fi

cp "$EXECUTABLE" "$MACOS_DIR/ZipMate"
chmod +x "$MACOS_DIR/ZipMate"
cp "$PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RESOURCES_DIR/ZipMate.icns"
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE"/. "$RESOURCES_DIR/"
fi

cat > "$CONTENTS_DIR/PkgInfo" <<'EOF'
APPL????
EOF

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || {
  echo "codesign failed for $APP_DIR" >&2
  exit 1
}

mkdir -p "$DMG_ROOT"
cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create \
  -volname "ZipMate" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "App: $APP_DIR"
echo "DMG: $DMG_PATH"
