#!/bin/bash
set -euo pipefail

APP="${1:?usage: strip-local-debug-symbols.sh /path/to/FloeBar.app}"

BINARIES=(
    "$APP/Contents/MacOS/FloeBar"
    "$APP/Contents/XPCServices/MenuBarItemService.xpc/Contents/MacOS/MenuBarItemService"
    "$APP/Contents/XPCServices/MenuBarCaptureService.xpc/Contents/MacOS/MenuBarCaptureService"
)

for binary in "${BINARIES[@]}"; do
    if [[ ! -f "$binary" ]]; then
        printf 'error: required executable is missing: %s\n' "$binary" >&2
        exit 1
    fi
    xcrun strip -S "$binary"
    if rg -q '[[:space:]](SO|OSO)[[:space:]]+/' < <(
        nm -a "$binary" 2>/dev/null || true
    ); then
        printf 'error: local debug paths remain in executable: %s\n' \
            "$binary" >&2
        exit 1
    fi
done
