#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun swiftc \
    "$ROOT/Shared/MenuBarItemService.swift" \
    "$ROOT/Tests/MenuBarItemServiceTests.swift" \
    -o "$TEMP_DIR/MenuBarItemServiceTests"
"$TEMP_DIR/MenuBarItemServiceTests"
