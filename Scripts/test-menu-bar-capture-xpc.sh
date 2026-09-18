#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: test-menu-bar-capture-xpc.sh /path/to/FloeBar.app}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

SERVICE_NAME="MenuBarCaptureService"
SERVICE_ID="com.evanzhu.FloeBar.MenuBarCaptureService"
SOURCE_SERVICE="$APP/Contents/XPCServices/$SERVICE_NAME.xpc"
PROBE="$TEMP_DIR/CaptureConnectionProbe.app"
PROBE_SERVICE="$PROBE/Contents/XPCServices/$SERVICE_NAME.xpc"

mkdir -p "$PROBE/Contents/MacOS" "$PROBE/Contents/XPCServices"
ditto "$SOURCE_SERVICE" "$PROBE_SERVICE"
test "$(plutil -extract CFBundleIdentifier raw \
    "$PROBE_SERVICE/Contents/Info.plist")" = "$SERVICE_ID"

plutil -create xml1 "$PROBE/Contents/Info.plist"
plutil -insert CFBundleIdentifier \
    -string local.floebar.CaptureConnectionProbe \
    "$PROBE/Contents/Info.plist"
plutil -insert CFBundleExecutable \
    -string CaptureConnectionProbe \
    "$PROBE/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$PROBE/Contents/Info.plist"

xcrun swiftc \
    "$ROOT/Shared/MenuBarCaptureService.swift" \
    "$ROOT/Tests/MenuBarCaptureServiceConnectionTests.swift" \
    -o "$PROBE/Contents/MacOS/CaptureConnectionProbe"
codesign --force --sign - --timestamp=none "$PROBE_SERVICE"
codesign --force --sign - --timestamp=none "$PROBE"
"$PROBE/Contents/MacOS/CaptureConnectionProbe"
