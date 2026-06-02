#!/bin/bash
# Build a release MacVoxCPM.app bundle. Modeled on CivitDown's build script.
# Output: build/stage/MacVoxCPM.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP_NAME="MacVoxCPM"
BUNDLE_ID="id.macvoxcpm.app"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DEPLOYMENT_TARGET="15.0"

BUILD_DIR="$ROOT/build"
STAGE="$BUILD_DIR/stage"
APP_DIR="$STAGE/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

if [ ! -x "$ROOT/Sources/MacVoxCPM/Resources/uv" ]; then
    echo "==> Resources/uv missing — running scripts/fetch-uv.sh"
    bash "$ROOT/scripts/fetch-uv.sh"
fi

echo "==> Cleaning previous build"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS" "$RESOURCES"

echo "==> Building release binary"
swift build -c release --arch arm64 --arch x86_64

EXE_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
if [ ! -x "$EXE_PATH" ]; then
    EXE_PATH="$ROOT/.build/apple/Products/Release/${APP_NAME}"
fi
if [ ! -x "$EXE_PATH" ]; then
    echo "Could not locate built binary at $EXE_PATH" >&2
    exit 1
fi

echo "==> Staging app bundle"
cp "$EXE_PATH" "$MACOS/${APP_NAME}"
chmod +x "$MACOS/${APP_NAME}"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>${DEPLOYMENT_TARGET}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>${APP_NAME}</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
        <string>${APP_NAME} does not record audio. Voice cloning uses files you import.</string>
</dict>
</plist>
PLIST

# Pull in SwiftPM resource bundle (uv binary + sidecar python live here).
RES_BUNDLE="$(dirname "$EXE_PATH")/${APP_NAME}_MacVoxCPM.bundle"
if [ -d "$RES_BUNDLE" ]; then
    cp -R "$RES_BUNDLE" "$RESOURCES/"
fi

ICON_SRC="$ROOT/assets/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$RESOURCES/AppIcon.icns"
fi

echo "==> Ad-hoc codesign (no notarization)"
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built: $APP_DIR"
