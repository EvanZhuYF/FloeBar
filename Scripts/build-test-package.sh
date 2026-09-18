#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${FLOEBAR_TEST_BUILD_ROOT:-$ROOT/build/test-package}"
DERIVED="$BUILD_ROOT/DerivedData"
DEST="$BUILD_ROOT/dist"
BUILD_BUNDLE_ID="${FLOEBAR_BUILD_BUNDLE_ID:-com.evanzhu.FloeBar.Build}"
VERSION="${FLOEBAR_MARKETING_VERSION:-1.0.6}"
BUILD_NUMBER="${FLOEBAR_BUILD_NUMBER:-1233}"
LABEL="${FLOEBAR_TEST_LABEL:-macos26-test}"
APP="$DEST/FloeBar.app"
ARM_APP="$DEST/FloeBar-arm64.app"

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
    -clonedSourcePackagesDirPath "$ROOT/build/local/SourcePackages" \
    -jobs 4 \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
    FLOEBAR_APP_BUNDLE_IDENTIFIER="$BUILD_BUNDLE_ID" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build

rm -rf "$APP" "$ARM_APP"
ditto "$DERIVED/Build/Products/Release/FloeBar.app" "$APP"
plutil -replace CFBundleIdentifier -string "com.evanzhu.FloeBar" "$APP/Contents/Info.plist"
plutil -replace IceLocalBuild -bool true "$APP/Contents/Info.plist" 2>/dev/null ||
    plutil -insert IceLocalBuild -bool true "$APP/Contents/Info.plist"
bash "$ROOT/Scripts/strip-local-debug-symbols.sh" "$APP"

SIGN_ID="${FLOEBAR_SIGN_ID:-FloeBar Self-Signed}"
if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    printf 'error: required signing certificate not found: %s\n' "$SIGN_ID" >&2
    exit 1
fi

sign_bundle() {
    local target="$1"
    local service="$target/Contents/XPCServices/MenuBarItemService.xpc"
    local capture_service="$target/Contents/XPCServices/MenuBarCaptureService.xpc"
    local sparkle="$target/Contents/Frameworks/Sparkle.framework"

    local service_id
    service_id="$(plutil -extract CFBundleIdentifier raw -o - \
        "$service/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$service_id" != "com.evanzhu.FloeBar.MenuBarItemService" ]]; then
        printf 'error: missing or incorrectly identified MenuBarItemService.xpc: %s\n' "$service_id" >&2
        exit 1
    fi
    local capture_service_id
    capture_service_id="$(plutil -extract CFBundleIdentifier raw -o - \
        "$capture_service/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$capture_service_id" != "com.evanzhu.FloeBar.MenuBarCaptureService" ]]; then
        printf 'error: missing or incorrectly identified MenuBarCaptureService.xpc: %s\n' "$capture_service_id" >&2
        exit 1
    fi
    codesign --force --sign "$SIGN_ID" --timestamp=none "$service"
    codesign --force --sign "$SIGN_ID" --timestamp=none "$capture_service"
    if [[ -d "$sparkle" ]]; then
        for component in \
            "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
            "$sparkle/Versions/B/XPCServices/Installer.xpc" \
            "$sparkle/Versions/B/Autoupdate" \
            "$sparkle/Versions/B/Updater.app" \
            "$sparkle/Versions/B/Sparkle" \
            "$sparkle"; do
            codesign --force --sign "$SIGN_ID" --timestamp=none "$component"
        done
    fi
    codesign --force --sign "$SIGN_ID" --timestamp=none "$target"
    codesign --verify --deep --strict --verbose=2 "$target"
}

thin_bundle_to_arm64() {
    local target="$1"
    local binary
    local architectures
    local output

    while IFS= read -r -d '' binary; do
        if [[ "$(file -b "$binary")" != Mach-O* ]]; then
            continue
        fi
        architectures="$(lipo "$binary" -archs)"
        if [[ " $architectures " != *" arm64 "* ]]; then
            printf 'error: missing arm64 architecture: %s\n' "$binary" >&2
            exit 1
        fi
        if [[ "$architectures" == "arm64" ]]; then
            continue
        fi
        output="$binary.arm64"
        lipo "$binary" -thin arm64 -output "$output"
        mv "$output" "$binary"
    done < <(find "$target" -type f -print0)
}

sign_bundle "$APP"
lipo "$APP/Contents/MacOS/FloeBar" -verify_arch arm64 x86_64
lipo "$APP/Contents/XPCServices/MenuBarItemService.xpc/Contents/MacOS/MenuBarItemService" \
    -verify_arch arm64 x86_64
lipo "$APP/Contents/XPCServices/MenuBarCaptureService.xpc/Contents/MacOS/MenuBarCaptureService" \
    -verify_arch arm64 x86_64

ditto "$APP" "$ARM_APP"
thin_bundle_to_arm64 "$ARM_APP"
sign_bundle "$ARM_APP"
lipo "$ARM_APP/Contents/MacOS/FloeBar" -verify_arch arm64
lipo "$ARM_APP/Contents/XPCServices/MenuBarItemService.xpc/Contents/MacOS/MenuBarItemService" \
    -verify_arch arm64
lipo "$ARM_APP/Contents/XPCServices/MenuBarCaptureService.xpc/Contents/MacOS/MenuBarCaptureService" \
    -verify_arch arm64

bash "$ROOT/Scripts/smoke-test-local.sh" "$APP" en
bash "$ROOT/Scripts/smoke-test-local.sh" "$APP" zh-Hans
bash "$ROOT/Scripts/test-production-xpc.sh" "$APP"
bash "$ROOT/Scripts/test-production-xpc.sh" "$ARM_APP"
bash "$ROOT/Scripts/test-xpc-connection.sh" "$APP"
bash "$ROOT/Scripts/test-xpc-connection.sh" "$ARM_APP"
bash "$ROOT/Scripts/test-menu-bar-capture-xpc.sh" "$APP"
bash "$ROOT/Scripts/test-menu-bar-capture-xpc.sh" "$ARM_APP"

UNIVERSAL_ZIP="$DEST/FloeBar-$VERSION-$LABEL-universal.zip"
ARM_ZIP="$DEST/FloeBar-$VERSION-$LABEL-arm64.zip"
rm -f "$UNIVERSAL_ZIP" "$ARM_ZIP" "$DEST/SHA256SUMS.txt"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UNIVERSAL_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ARM_APP" "$ARM_ZIP"
(
    cd "$DEST"
    shasum -a 256 \
        "$(basename "$UNIVERSAL_ZIP")" \
        "$(basename "$ARM_ZIP")" \
        > SHA256SUMS.txt
)

printf '\nSigning: %s\n' "$SIGN_ID"
printf 'Universal: %s\n' "$UNIVERSAL_ZIP"
printf 'Arm64: %s\n' "$ARM_ZIP"
printf 'Checksums: %s\n' "$DEST/SHA256SUMS.txt"
