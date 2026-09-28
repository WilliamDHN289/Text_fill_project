#!/bin/bash
set -euo pipefail

# Configuration
APP_NAME="FlowIn"
BUNDLE_ID="com.astrabreeze.autocomplete"
SIGNING_IDENTITY="Developer ID Application: Astrabreeze, Inc. (K28M9T5LYR)"
KEYCHAIN_PROFILE="AC_PASSWORD"
VERSION="${1:-1.0.0}"

# Paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/dist/${APP_NAME}.app"
DMG_PATH="$PROJECT_DIR/dist/${APP_NAME}-${VERSION}.dmg"
RESOURCES_DIR="$PROJECT_DIR/Resources"
ENTITLEMENTS="$RESOURCES_DIR/Autocomplete.entitlements"

echo "=== Building ${APP_NAME} v${VERSION} ==="

# Clean previous build
rm -rf "$PROJECT_DIR/dist"
mkdir -p "$PROJECT_DIR/dist"

# Step 1: Build Swift release binary
echo "--- Building Swift binary (release) ---"
cd "$PROJECT_DIR"
swift build -c release

# Step 2: Assemble .app bundle
echo "--- Assembling app bundle ---"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy binary and strip debug symbols
cp "$BUILD_DIR/Autocomplete" "$APP_BUNDLE/Contents/MacOS/Autocomplete"
strip -x "$APP_BUNDLE/Contents/MacOS/Autocomplete"
echo "Debug symbols stripped from binary."

# Copy llama.cpp frameworks
FRAMEWORKS_DIR="$PROJECT_DIR/Frameworks"
cp "$FRAMEWORKS_DIR"/libllama.0.dylib "$APP_BUNDLE/Contents/Frameworks/"
cp "$FRAMEWORKS_DIR"/libggml.0.dylib "$APP_BUNDLE/Contents/Frameworks/"
cp "$FRAMEWORKS_DIR"/libggml-base.0.dylib "$APP_BUNDLE/Contents/Frameworks/"
cp "$FRAMEWORKS_DIR"/libggml-cpu.0.dylib "$APP_BUNDLE/Contents/Frameworks/"
cp "$FRAMEWORKS_DIR"/libggml-metal.0.dylib "$APP_BUNDLE/Contents/Frameworks/"
cp "$FRAMEWORKS_DIR"/libggml-blas.0.dylib "$APP_BUNDLE/Contents/Frameworks/"
cp "$FRAMEWORKS_DIR"/ggml-metal.metal "$APP_BUNDLE/Contents/Resources/"
# Strip debug symbols from dylibs to reduce bundle size
for dylib in "$APP_BUNDLE/Contents/Frameworks/"*.dylib; do
    strip -x "$dylib"
done
echo "llama.cpp libraries bundled and stripped."

# Copy Sparkle.framework
SPARKLE_FW="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"
    echo "Sparkle.framework bundled."
else
    echo "Warning: Sparkle.framework not found at $SPARKLE_FW"
fi

# Copy app icon
cp "$RESOURCES_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy Info.plist
cp "$RESOURCES_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Update version in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"

echo "--- Bundle size: $(du -sh "$APP_BUNDLE" | cut -f1) ---"

# Step 3: Code sign
echo "--- Code signing ---"
# Sign embedded dylibs first
for dylib in "$APP_BUNDLE/Contents/Frameworks/"*.dylib; do
    codesign --force --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$dylib"
done

# Sign Sparkle.framework (sign nested XPC services first)
if [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
    for xpc in "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.xpc; do
        codesign --force --options runtime \
            --sign "$SIGNING_IDENTITY" \
            "$xpc"
    done
    codesign --force --options runtime \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# Sign the app bundle
codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"

# Verify signature
codesign --verify --deep --strict "$APP_BUNDLE"
echo "Code signing verified."

# Step 4: Create DMG with drag-to-install layout
echo "--- Creating DMG ---"
DMG_STAGING="$PROJECT_DIR/dist/dmg-staging"
TEMP_DMG="$PROJECT_DIR/dist/${APP_NAME}-temp.dmg"
VOLUME_NAME="Install ${APP_NAME}"
MOUNT_DIR="/Volumes/${VOLUME_NAME}"

rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Background image with drag arrow between FlowIn and Applications
mkdir -p "$DMG_STAGING/.background"
cp "$RESOURCES_DIR/dmg-background.png" "$DMG_STAGING/.background/background.png"

# Build writable DMG so we can stamp icon positions / view options
rm -f "$TEMP_DMG"
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDRW -fs HFS+ \
    "$TEMP_DMG"

# Detach any prior mount that would block ours
hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true

hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -noautoopen

# Configure window: icon view, no toolbar/sidebar, FlowIn on the left,
# Applications folder on the right.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 700, 470}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set text size of viewOptions to 12
        set label position of viewOptions to bottom
        set background picture of viewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {130, 130}
        set position of item "Applications" of container window to {370, 130}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR"

# Convert writable DMG to compressed read-only
rm -f "$DMG_PATH"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$TEMP_DMG"
rm -rf "$DMG_STAGING"

# Sign the DMG
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"

# Step 5: Notarize
echo "--- Submitting for notarization ---"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

# Step 6: Staple
echo "--- Stapling notarization ticket ---"
xcrun stapler staple "$DMG_PATH"

# Also staple the .app inside for direct distribution
xcrun stapler staple "$APP_BUNDLE"

# Step 7: Sparkle EdDSA signature for appcast
SIGN_TOOL="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
echo ""
echo "=== Sparkle appcast entry (paste into appcast.xml) ==="
if [ -x "$SIGN_TOOL" ]; then
    "$SIGN_TOOL" "$DMG_PATH"
else
    echo "Warning: sign_update not found at $SIGN_TOOL — run 'swift build' once to fetch Sparkle artifacts"
fi

echo ""
echo "=== Build complete ==="
echo "DMG: $DMG_PATH"
echo "App: $APP_BUNDLE"
echo "Size: $(du -sh "$DMG_PATH" | cut -f1)"
