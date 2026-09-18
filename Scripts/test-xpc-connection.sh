#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: test-xpc-connection.sh /path/to/FloeBar.app}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
PROBE="$TEMP_DIR/ConnectionProbe.app"
mkdir -p "$PROBE/Contents/MacOS" "$PROBE/Contents/XPCServices"
ditto "$APP/Contents/XPCServices/MenuBarItemService.xpc" "$PROBE/Contents/XPCServices/MenuBarItemService.xpc"
test "$(plutil -extract CFBundleIdentifier raw "$PROBE/Contents/XPCServices/MenuBarItemService.xpc/Contents/Info.plist")" = "com.evanzhu.FloeBar.MenuBarItemService"
plutil -create xml1 "$PROBE/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string local.floebar.ConnectionProbe "$PROBE/Contents/Info.plist"
plutil -insert CFBundleExecutable -string ConnectionProbe "$PROBE/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$PROBE/Contents/Info.plist"
xcrun swiftc "$ROOT/Shared/MenuBarItemService.swift" \
    "$ROOT/Tests/MenuBarItemServiceConnectionTests.swift" -o "$PROBE/Contents/MacOS/ConnectionProbe"
codesign --force --sign - --timestamp=none "$PROBE/Contents/XPCServices/MenuBarItemService.xpc"
codesign --force --sign - --timestamp=none "$PROBE"
"$PROBE/Contents/MacOS/ConnectionProbe"
