#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun swiftc \
    "$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemSectionStore.swift" \
    "$ROOT/Tests/SectionPersistenceTests.swift" \
    -o "$TEMP_DIR/SectionPersistenceTests"
"$TEMP_DIR/SectionPersistenceTests"
