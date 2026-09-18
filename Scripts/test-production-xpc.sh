#!/bin/bash
set -euo pipefail

APP="${1:?usage: test-production-xpc.sh /path/to/FloeBar.app}"
TEMP_DIR="$(mktemp -d)"
COPY="$TEMP_DIR/FloeBar.app"
LOG="$TEMP_DIR/xpc.log"
trap 'rm -rf "$TEMP_DIR"' EXIT

ditto "$APP" "$COPY"
plutil -replace CFBundleIdentifier \
    -string "local.floebar.xpc.$(uuidgen)" \
    "$COPY/Contents/Info.plist"

for service in MenuBarItemService MenuBarCaptureService; do
    codesign --force --sign - --timestamp=none \
        "$COPY/Contents/XPCServices/$service.xpc"
done
codesign --force --sign - --timestamp=none "$COPY"
codesign --verify --deep --strict "$COPY"

"$COPY/Contents/MacOS/FloeBar" --verify-embedded-services >"$LOG" 2>&1 &
pid=$!
for _ in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then
        if wait "$pid" && grep -Fq \
            "PASS: production embedded XPC connections" "$LOG"; then
            cat "$LOG"
            exit 0
        fi
        cat "$LOG" >&2
        exit 1
    fi
    sleep 0.1
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
cat "$LOG" >&2
printf 'FAIL: production XPC verification timed out\n' >&2
exit 1
