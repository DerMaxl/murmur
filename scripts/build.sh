#!/bin/bash
# Build Murmur.app, compiles with SwiftPM, assembles the .app bundle, and signs
# it. No Xcode required.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIG="${1:-debug}"            # debug | release
APP_NAME="Murmur"
BUNDLE_ID="com.murmur.app"
IDENTITY_NAME="Murmur Self-Signed"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "==> Compiling ($CONFIG)..."
if [ "$CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [ -f "$ROOT/Resources/MenuBarIcon.png" ]; then
    cp "$ROOT/Resources/MenuBarIcon.png" "$APP_DIR/Contents/Resources/MenuBarIcon.png"
fi

# Choose signing identity: stable self-signed if present, else ad-hoc.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    SIGN_ID="$IDENTITY_NAME"
    echo "==> Signing with '$SIGN_ID' (stable; TCC grants persist)."
else
    SIGN_ID="-"
    echo "==> Signing ad-hoc. Run ./scripts/make-cert.sh for persistent permissions."
fi

codesign --force \
    --options runtime \
    --entitlements "$ROOT/Resources/Murmur.entitlements" \
    --sign "$SIGN_ID" \
    "$APP_DIR"

echo "==> Built: $APP_DIR"
echo "    Launch:  open \"$APP_DIR\""
