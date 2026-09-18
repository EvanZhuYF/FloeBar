#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun swiftc \
    "$ROOT/Shared/MenuBarCaptureService.swift" \
    "$ROOT/Tests/MenuBarCaptureServicePolicyTests.swift" \
    -o "$TEMP_DIR/MenuBarCaptureServicePolicyTests"
"$TEMP_DIR/MenuBarCaptureServicePolicyTests"
