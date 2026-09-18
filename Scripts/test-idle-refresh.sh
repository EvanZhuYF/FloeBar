#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/FloeBar/MenuBar/Appearance/MenuBarOverlayPanel.swift"
APPEARANCE_MANAGER="$ROOT/FloeBar/MenuBar/Appearance/MenuBarAppearanceManager.swift"
ICE_BAR_COLOR="$ROOT/FloeBar/UI/IceBar/IceBarColorManager.swift"
ITEM_MANAGER="$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemManager.swift"
SOURCE_PID_RESOLVER="$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemSourcePIDResolver.swift"
SERVICE_RESOLVER="$ROOT/MenuBarItemService/SourcePIDResolver.swift"
SCREEN_CAPTURE="$ROOT/FloeBar/Utilities/ScreenCapture.swift"
MENU_BAR_MANAGER="$ROOT/FloeBar/MenuBar/MenuBarManagement/MenuBarManager.swift"
ICE_BAR_COLOR_MANAGER="$ROOT/FloeBar/UI/IceBar/IceBarColorManager.swift"

if rg -q 'Timer\.publish\(every:' "$OVERLAY"; then
    printf 'FAIL: overlay panels must not own periodic timers\n' >&2
    exit 1
fi

if [[ "$(rg -c 'Timer\.publish\(every: 10' "$APPEARANCE_MANAGER")" != "1" ]]; then
    printf 'FAIL: expected one shared appearance refresh timer\n' >&2
    exit 1
fi

rg -q 'let visibleRefreshTimer' "$ICE_BAR_COLOR"
rg -q 'windowImage = nil' "$ICE_BAR_COLOR"
rg -q 'iceBarPanel\.isVisible' "$ICE_BAR_COLOR"
rg -q 'scheduleCacheRefresh\(after: \.milliseconds\(150\)\)' "$ITEM_MANAGER"
rg -q 'case 2: 15' "$SOURCE_PID_RESOLVER"
rg -q 'default: 60' "$SOURCE_PID_RESOLVER"
rg -q 'scanBudget: Duration = \.seconds\(5\)' "$SERVICE_RESOLVER"
rg -q 'minimumInterval: Duration = \.seconds\(15\)' "$SCREEN_CAPTURE"
rg -q 'onScreenWindowsOnly: true' "$SCREEN_CAPTURE"
rg -q 'average-color-' "$MENU_BAR_MANAGER"
rg -q 'ice-bar-color-' "$ICE_BAR_COLOR_MANAGER"
rg -q 'overlay-wallpaper-' "$OVERLAY"

if rg -q 'sectionObservationPending = .*hasProvisionalIdentity' "$ITEM_MANAGER"; then
    printf 'FAIL: unresolved identities must not force a full cache every timer tick\n' >&2
    exit 1
fi

printf 'PASS: idle refresh invariants\n'
