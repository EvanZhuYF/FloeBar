#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
xcrun swiftc \
    "$ROOT/Shared/WindowDescriptionQuery.swift" \
    "$ROOT/FloeBar/Utilities/WindowInfo.swift" \
    "$ROOT/Tests/WindowDescriptionTests.swift" \
    -o "$TEMP_DIR/WindowDescriptionTests"
"$TEMP_DIR/WindowDescriptionTests"
