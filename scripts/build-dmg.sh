#!/bin/bash
# Build MacVoxCPM.app and wrap it in a distributable (non-notarized) DMG with a
# drag-to-Applications shortcut.
# Output: build/MacVoxCPM-<version>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="MacVoxCPM"
VERSION="${1:-0.1.0}"

BUILD_DIR="$ROOT/build"
STAGE="$BUILD_DIR/stage"
APP_DIR="$STAGE/${APP_NAME}.app"
DMG_STAGE="$BUILD_DIR/dmg"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

echo "==> Building app bundle (version $VERSION)"
bash "$ROOT/scripts/build-app.sh" "$VERSION"

if [ ! -d "$APP_DIR" ]; then
    echo "Expected app at $APP_DIR but it is missing" >&2
    exit 1
fi

echo "==> Staging DMG contents"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_DIR" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

echo "==> Creating DMG"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"
echo "Built: $DMG_PATH ($SIZE)"
