#!/bin/bash
# Builds a universal (Apple silicon + Intel) PixView.app and packages it as build/PixView-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/PixView"

STAGE="build/dmg"
APP="$STAGE/PixView.app"
DMG="build/PixView-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PixView"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

hdiutil create -volname "PixView $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $(pwd)/$DMG"
