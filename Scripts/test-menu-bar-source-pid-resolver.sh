#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun swiftc \
    "$ROOT/Shared/MenuBarItemService.swift" \
    "$ROOT/Tests/MenuBarItemSourcePIDResolverTestSupport.swift" \
    "$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemSourcePIDResolver.swift" \
    "$ROOT/Tests/MenuBarItemSourcePIDResolverTests.swift" \
    -o "$TEMP_DIR/MenuBarItemSourcePIDResolverTests"
"$TEMP_DIR/MenuBarItemSourcePIDResolverTests"
