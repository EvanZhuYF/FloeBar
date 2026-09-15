#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${ICE_BUILD_ROOT:-$ROOT/build/local}"
DERIVED="$BUILD_ROOT/DerivedData"
DEST="$BUILD_ROOT/dist"
mkdir -p "$DEST"

bash "$ROOT/Scripts/test-section-persistence.sh"
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
    MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=1206 \
    build

APP="$DEST/FloeBar.app"
if [[ -e "$APP" ]]; then
    mv "$APP" "$DEST/FloeBar-previous-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$DERIVED/Build/Products/Release/FloeBar.app" "$APP"
# IceLocalBuild is the internal flag UpdatesManager reads to disable self-updates.
plutil -insert IceLocalBuild -bool true "$APP/Contents/Info.plist"

# Sign inside-out. Ad-hoc signatures cannot use hardened runtime library validation.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    for COMPONENT in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app" \
        "$SPARKLE/Versions/B/Sparkle" \
        "$SPARKLE"; do
        codesign --force --sign - --timestamp=none "$COMPONENT"
    done
fi
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo "$APP/Contents/MacOS/FloeBar" -verify_arch arm64 x86_64
bash "$ROOT/Scripts/smoke-test-local.sh" "$APP" en
bash "$ROOT/Scripts/smoke-test-local.sh" "$APP" zh-Hans
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DEST/FloeBar-1.0.0-local-universal.zip"
shasum -a 256 "$DEST/FloeBar-1.0.0-local-universal.zip"
printf '\nLocal app: %s\n' "$APP"
