#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

xcrun swiftc \
    "$ROOT/Tests/MenuBarItemIdentityTestSupport.swift" \
    "$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemInfo.swift" \
    "$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItem.swift" \
    "$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemPersistenceIdentityPolicy.swift" \
    "$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemSectionStore.swift" \
    "$ROOT/FloeBar/Extensions/Sequence/Sequence+sortedByOrderInMenuBar.swift" \
    "$ROOT/FloeBar/Extensions/NSScreen/NSScreen+screenWithMouse.swift" \
    "$ROOT/Tests/MenuBarItemIdentityTests.swift" \
    -o "$TEMP_DIR/ItemIdentityTests"
"$TEMP_DIR/ItemIdentityTests"
