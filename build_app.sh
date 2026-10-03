#!/bin/zsh
set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Building release binary"
swift build -c release --disable-sandbox

APP_NAME="ChassisWatcher"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "==> Assembling app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Code signing (ad hoc, with sandbox + network entitlements)"
codesign --force --deep --options runtime --sign - --entitlements entitlements.plist "$APP_BUNDLE"

echo "==> Verifying signature"
codesign --verify --verbose=2 "$APP_BUNDLE"

echo "==> Done. App bundle: $APP_BUNDLE"
echo "    Run it manually first with: open \"$APP_BUNDLE\""
echo "    Watch logs with: tail -f ~/Library/Containers/com.example.chassiswatcher/Data/Library/Logs/ChassisWatcher/chassiswatcher.log"
