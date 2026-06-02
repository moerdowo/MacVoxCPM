#!/bin/bash
# Download the pinned uv binary into Sources/MacVoxCPM/Resources/uv so SwiftPM
# bundles it into the app. Also stages the sidecar Python sources next to it.
#
# Run this once before the first `swift build` (or `scripts/build-app.sh`).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

UV_VERSION="${UV_VERSION:-0.5.20}"
RES_DIR="$ROOT/Sources/MacVoxCPM/Resources"
SIDECAR_SRC="$ROOT/sidecar"
SIDECAR_DST="$RES_DIR/sidecar"

mkdir -p "$RES_DIR"

# --- uv binary ---------------------------------------------------------------

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  UV_TARGET="aarch64-apple-darwin" ;;
    x86_64) UV_TARGET="x86_64-apple-darwin"  ;;
    *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${UV_TARGET}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading uv ${UV_VERSION} for ${UV_TARGET}"
curl -fL --retry 3 -o "$TMP/uv.tar.gz" "$UV_URL"
tar -xzf "$TMP/uv.tar.gz" -C "$TMP"

# The tarball lays out uv-${UV_TARGET}/uv -- locate it.
UV_BIN="$(find "$TMP" -maxdepth 3 -type f -name 'uv' -perm -u+x | head -n1)"
if [ -z "${UV_BIN:-}" ] || [ ! -x "$UV_BIN" ]; then
    echo "Could not find uv binary in tarball" >&2
    exit 1
fi

cp "$UV_BIN" "$RES_DIR/uv"
chmod +x "$RES_DIR/uv"
echo "    staged $(ls -lh "$RES_DIR/uv" | awk '{print $5}')  ->  $RES_DIR/uv"

# --- sidecar python source ---------------------------------------------------

echo "==> Staging sidecar source"
rm -rf "$SIDECAR_DST"
mkdir -p "$SIDECAR_DST"
cp "$SIDECAR_SRC/server.py"     "$SIDECAR_DST/server.py"
cp "$SIDECAR_SRC/pyproject.toml" "$SIDECAR_DST/pyproject.toml"
echo "    -> $SIDECAR_DST"

echo "Done."
