#!/bin/bash
set -euo pipefail

APP="${1:?Pass the built FloeBar.app path}"
LANGUAGE="${2:-en}"
TEMP_DIR="$(mktemp -d)"
PID=""
COPY=""
MAIN_BUNDLE_ID="com.evanzhu.FloeBar"
SMOKE_BUNDLE_PREFIX="local.floebar.smoke."
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup_smoke_section_records() {
    local exported="$TEMP_DIR/main-defaults.plist"
    local filtered="$TEMP_DIR/main-defaults-filtered.plist"
    if ! defaults export "$MAIN_BUNDLE_ID" "$exported" >/dev/null 2>&1; then
        return
    fi
    if /usr/bin/python3 - "$exported" "$filtered" "$SMOKE_BUNDLE_PREFIX" <<'PY'
import json
import plistlib
import sys

source_path, output_path, prefix = sys.argv[1:]
with open(source_path, "rb") as f:
    domain = plistlib.load(f)

data = domain.get("MenuBarItemSectionsV1")
if not isinstance(data, (bytes, bytearray)):
    sys.exit(2)

document = json.loads(data)
records = document.get("records", [])
filtered = [
    record for record in records
    if not record.get("identity", {}).get("bundleIdentifier", "").startswith(prefix)
]
if len(filtered) == len(records):
    sys.exit(2)

document["records"] = filtered
domain["MenuBarItemSectionsV1"] = json.dumps(
    document,
    separators=(",", ":"),
    sort_keys=True,
).encode("utf-8")

with open(output_path, "wb") as f:
    plistlib.dump(domain, f)
PY
    then
        defaults import "$MAIN_BUNDLE_ID" "$filtered" >/dev/null 2>&1 || true
    fi
}

cleanup() {
    if [[ -n "$PID" ]]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    cleanup_smoke_section_records
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
MENU_BAR_SERVICE="$COPY/Contents/XPCServices/MenuBarItemService.xpc"
if [[ -d "$MENU_BAR_SERVICE" ]]; then
    codesign --force --sign - --timestamp=none "$MENU_BAR_SERVICE"
fi
CAPTURE_SERVICE="$COPY/Contents/XPCServices/MenuBarCaptureService.xpc"
if [[ -d "$CAPTURE_SERVICE" ]]; then
    codesign --force --sign - --timestamp=none "$CAPTURE_SERVICE"
fi
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
