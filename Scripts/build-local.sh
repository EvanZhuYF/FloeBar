#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${ICE_BUILD_ROOT:-$ROOT/build/local}"
DERIVED="$BUILD_ROOT/DerivedData"
DEST="$BUILD_ROOT/dist"
BUILD_BUNDLE_ID="${FLOEBAR_BUILD_BUNDLE_ID:-com.evanzhu.FloeBar.Build}"
RELEASE_BUNDLE_ID="com.evanzhu.FloeBar"
MARKETING_VERSION="${FLOEBAR_MARKETING_VERSION:-1.0.5}"
BUILD_NUMBER="${FLOEBAR_BUILD_NUMBER:-1226}"
mkdir -p "$DEST"

bash "$ROOT/Scripts/test-section-persistence.sh"
bash "$ROOT/Scripts/test-menu-bar-item-service.sh"
bash "$ROOT/Scripts/test-menu-bar-capture-service.sh"
bash "$ROOT/Scripts/test-menu-bar-capture-policy.sh"
bash "$ROOT/Scripts/test-menu-bar-source-pid-resolver.sh"
bash "$ROOT/Scripts/test-screen-capture-coordinator.sh"
bash "$ROOT/Scripts/test-item-identity.sh"
bash "$ROOT/Scripts/test-window-descriptions.sh"
bash "$ROOT/Scripts/test-localizations.sh"
bash "$ROOT/Scripts/test-idle-refresh.sh"
xcodebuild -quiet \
    -project "$ROOT/FloeBar.xcodeproj" -scheme FloeBar -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/SourcePackages" \
    -jobs 4 \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
    FLOEBAR_APP_BUNDLE_IDENTIFIER="$BUILD_BUNDLE_ID" \
    MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build

APP="$DEST/FloeBar.app"
if [[ -e "$APP" ]]; then
    mv "$APP" "$DEST/FloeBar-previous-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$DERIVED/Build/Products/Release/FloeBar.app" "$APP"
plutil -replace CFBundleIdentifier -string "$RELEASE_BUNDLE_ID" "$APP/Contents/Info.plist"
# IceLocalBuild is the internal flag UpdatesManager reads to disable self-updates.
plutil -insert IceLocalBuild -bool true "$APP/Contents/Info.plist"
bash "$ROOT/Scripts/strip-local-debug-symbols.sh" "$APP"

# Keep the same signing identity as published builds for stable permissions.
# FLOEBAR_SIGN_ID can explicitly override this for other build environments.
SIGN_ID="${FLOEBAR_SIGN_ID:-FloeBar Self-Signed}"

# Sign inside-out. Ad-hoc signatures cannot use hardened runtime library validation.
MENU_BAR_SERVICE="$APP/Contents/XPCServices/MenuBarItemService.xpc"
CAPTURE_SERVICE="$APP/Contents/XPCServices/MenuBarCaptureService.xpc"
SERVICE_ID="$(plutil -extract CFBundleIdentifier raw -o - \
    "$MENU_BAR_SERVICE/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$SERVICE_ID" != "com.evanzhu.FloeBar.MenuBarItemService" ]]; then
    printf 'error: missing or incorrectly identified MenuBarItemService.xpc: %s\n' "$SERVICE_ID" >&2
    exit 1
fi
CAPTURE_SERVICE_ID="$(plutil -extract CFBundleIdentifier raw -o - \
    "$CAPTURE_SERVICE/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$CAPTURE_SERVICE_ID" != "com.evanzhu.FloeBar.MenuBarCaptureService" ]]; then
    printf 'error: missing or incorrectly identified MenuBarCaptureService.xpc: %s\n' "$CAPTURE_SERVICE_ID" >&2
    exit 1
fi
codesign --force --sign "$SIGN_ID" --timestamp=none "$MENU_BAR_SERVICE"
codesign --force --sign "$SIGN_ID" --timestamp=none "$CAPTURE_SERVICE"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    for COMPONENT in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app" \
        "$SPARKLE/Versions/B/Sparkle" \
        "$SPARKLE"; do
        codesign --force --sign "$SIGN_ID" --timestamp=none "$COMPONENT"
    done
fi
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo "$APP/Contents/MacOS/FloeBar" -verify_arch arm64 x86_64
lipo "$MENU_BAR_SERVICE/Contents/MacOS/MenuBarItemService" \
    -verify_arch arm64 x86_64
lipo "$CAPTURE_SERVICE/Contents/MacOS/MenuBarCaptureService" \
    -verify_arch arm64 x86_64
bash "$ROOT/Scripts/smoke-test-local.sh" "$APP" en
bash "$ROOT/Scripts/smoke-test-local.sh" "$APP" zh-Hans
bash "$ROOT/Scripts/test-production-xpc.sh" "$APP"
bash "$ROOT/Scripts/test-xpc-connection.sh" "$APP"
bash "$ROOT/Scripts/test-menu-bar-capture-xpc.sh" "$APP"
ARCHIVE="$DEST/FloeBar-$MARKETING_VERSION-local-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE"

# Keep LaunchServices from choosing an ad-hoc DerivedData or dist copy when
# launching FloeBar by name. Only the installed /Applications copy should be
# eligible for normal use and TCC permission checks.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for LOCAL_APP in \
    "$DERIVED/Build/Products/Release/FloeBar.app" \
    "$BUILD_ROOT/DerivedData-arm64/Build/Products/Release/FloeBar.app" \
    "$APP" \
    "$DEST/FloeBar-arm64.app"; do
    if [[ -d "$LOCAL_APP" ]]; then
        "$LSREGISTER" -u "$LOCAL_APP" >/dev/null 2>&1 || true
    fi
done
if [[ -d "/Applications/FloeBar.app" ]]; then
    "$LSREGISTER" -f "/Applications/FloeBar.app" >/dev/null 2>&1 || true
fi
"$LSREGISTER" -gc >/dev/null 2>&1 || true

printf '\nLocal app: %s\n' "$APP"
