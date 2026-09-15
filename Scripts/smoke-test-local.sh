#!/bin/bash
set -euo pipefail

APP="${1:?Pass the built FloeBar.app path}"
LANGUAGE="${2:-en}"
TEMP_DIR="$(mktemp -d)"
PID=""
COPY=""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
cleanup() {
    if [[ -n "$PID" ]]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    if [[ -n "$COPY" && -d "$COPY" ]]; then
        "$LSREGISTER" -u "$COPY" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# A new bundle ID isolates settings and permissions from the installed FloeBar.
# Do not grant permissions: this tests startup/dylib loading, not menu bar moves.
COPY="$TEMP_DIR/FloeBar.app"
ditto "$APP" "$COPY"
plutil -replace CFBundleIdentifier -string "local.floebar.smoke.$(uuidgen)" "$COPY/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$COPY"
"$COPY/Contents/MacOS/FloeBar" \
    -AppleLanguages "($LANGUAGE)" \
    > "$TEMP_DIR/launch.log" 2>&1 &
PID=$!
sleep 5
if ! kill -0 "$PID" 2>/dev/null; then
    cat "$TEMP_DIR/launch.log"
    printf 'FAIL: FloeBar exited during startup\n' >&2
    exit 1
fi
printf 'PASS: FloeBar stayed running for 5 seconds (language: %s)\n' "$LANGUAGE"
