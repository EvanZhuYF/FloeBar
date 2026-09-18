#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/FloeBar/MenuBar/Appearance/MenuBarOverlayPanel.swift"
APPEARANCE_MANAGER="$ROOT/FloeBar/MenuBar/Appearance/MenuBarAppearanceManager.swift"
ICE_BAR_COLOR="$ROOT/FloeBar/UI/IceBar/IceBarColorManager.swift"
ITEM_MANAGER="$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemManager.swift"
ITEM_IMAGE_CACHE="$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemImageCache.swift"
SOURCE_PID_RESOLVER="$ROOT/FloeBar/MenuBar/ItemManagement/MenuBarItemSourcePIDResolver.swift"
SERVICE_RESOLVER="$ROOT/MenuBarItemService/SourcePIDResolver.swift"
SCREEN_CAPTURE="$ROOT/FloeBar/Utilities/ScreenCapture.swift"
MENU_BAR_MANAGER="$ROOT/FloeBar/MenuBar/MenuBarManagement/MenuBarManager.swift"
ICE_BAR_COLOR_MANAGER="$ROOT/FloeBar/UI/IceBar/IceBarColorManager.swift"
APP_STATE="$ROOT/FloeBar/Main/AppState.swift"
LAYOUT_PANE="$ROOT/FloeBar/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift"
LAYOUT_CONTAINER="$ROOT/FloeBar/UI/LayoutBar/LayoutBarContainer.swift"
ADVANCED_PANE="$ROOT/FloeBar/Settings/SettingsPanes/AdvancedSettingsPane.swift"
HOTKEYS_PANE="$ROOT/FloeBar/Settings/SettingsPanes/HotkeysSettingsPane.swift"

if rg -q 'Timer\.publish\(every:' "$OVERLAY"; then
    printf 'FAIL: overlay panels must not own periodic timers\n' >&2
    exit 1
fi

if [[ "$(rg -c 'Timer\.publish\(every: 30' "$APPEARANCE_MANAGER")" != "1" ]]; then
    printf 'FAIL: expected one low-frequency shared appearance refresh timer\n' >&2
    exit 1
fi

rg -q 'let visibleRefreshTimer' "$ICE_BAR_COLOR"
rg -q 'Timer\.publish\(every: 15' "$ICE_BAR_COLOR"
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
rg -q 'private func updateCacheForTimer' "$ITEM_IMAGE_CACHE"
rg -q 'Timer\.publish\(every: 15' "$ITEM_IMAGE_CACHE"
rg -q 'visibleItemsRequireLegacyCapture' "$ITEM_IMAGE_CACHE"
rg -q 'isMenuBarLayoutPresented' "$ITEM_IMAGE_CACHE"
rg -q 'NSApp\.windows\.contains' "$ITEM_IMAGE_CACHE"
rg -q 'periodicUpdateTask' "$ITEM_IMAGE_CACHE"
rg -q 'Timer\.publish\(every: 15' "$MENU_BAR_MANAGER"
rg -q 'waitForCorrectPosition' "$ITEM_MANAGER"
rg -q 'timeout: \.milliseconds\(250\)' "$ITEM_MANAGER"
rg -q 'updateCacheWithoutChecks' "$LAYOUT_PANE"
rg -q 'return section == \.visible && item\.info == \.iceIcon' "$ITEM_MANAGER"
rg -q 'isVisibleControlItem = item\.info == \.iceIcon && section == \.visible' "$ITEM_MANAGER"
rg -q 'sourceView\.item\.info != \.iceIcon' "$LAYOUT_CONTAINER"
rg -q 'if !appState\.settingsManager\.generalSettingsManager\.useIceBar' "$ADVANCED_PANE"
rg -q 'if !appState\.settingsManager\.generalSettingsManager\.useIceBar' "$HOTKEYS_PANE"

if rg -q 'imageCache\.updateCacheWithoutChecks' "$APP_STATE"; then
    printf 'FAIL: AppState must not duplicate layout-pane image refreshes\n' >&2
    exit 1
fi

if rg -q 'sectionObservationPending = .*hasProvisionalIdentity' "$ITEM_MANAGER"; then
    printf 'FAIL: unresolved identities must not force a full cache every timer tick\n' >&2
    exit 1
fi

printf 'PASS: idle refresh invariants\n'
