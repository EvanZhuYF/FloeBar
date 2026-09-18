#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun swiftc \
    "$ROOT/Shared/MenuBarCaptureService.swift" \
    "$ROOT/Tests/MenuBarCaptureServiceTests.swift" \
    -o "$TEMP_DIR/MenuBarCaptureServiceTests"
"$TEMP_DIR/MenuBarCaptureServiceTests"
