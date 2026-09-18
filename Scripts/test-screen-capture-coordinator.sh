#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun swiftc \
    -D SCREEN_CAPTURE_COORDINATOR_TESTS \
    -target "$(uname -m)-apple-macos14.0" \
    "$ROOT/Tests/ScreenCaptureCoordinatorTestSupport.swift" \
    "$ROOT/FloeBar/Utilities/ScreenCapture.swift" \
    "$ROOT/Tests/ScreenCaptureCoordinatorTests.swift" \
    -framework ScreenCaptureKit \
    -o "$TEMP_DIR/ScreenCaptureCoordinatorTests"
"$TEMP_DIR/ScreenCaptureCoordinatorTests"
