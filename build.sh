#!/bin/bash
# Builds PixView.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PixView"

APP="build/PixView.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PixView"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"

# ./build.sh --install  also copies the app into /Applications
if [ "${1:-}" = "--install" ]; then
    pkill -x PixView 2>/dev/null || true
    rm -rf /Applications/PixView.app
    ditto "$APP" /Applications/PixView.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PixView.app
    echo "Installed /Applications/PixView.app"
fi
