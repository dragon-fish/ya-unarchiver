#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP_NAME="YAUnarchiver"
BIN_NAME="YAUnarchiver"          # must match CFBundleExecutable
EXEC_TARGET="SevenZipApp"        # SwiftPM product name

SDK="$(xcrun --show-sdk-path)"
echo "Building ($CONFIG)…"
swift build -c "$CONFIG" \
    -Xswiftc -sdk -Xswiftc "$SDK" \
    -Xswiftc -target -Xswiftc arm64-apple-macos14.0

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP=".build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$EXEC_TARGET" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Bundle the 7zz binary if present (added in Task 10).
if [[ -f Resources/7zz ]]; then
    cp Resources/7zz "$APP/Contents/Resources/7zz"
    chmod +x "$APP/Contents/Resources/7zz"
fi

codesign --force --sign - "$APP"
echo "Built: $APP"
