#!/bin/bash
# Release build + publish for FloeBar.
#
# Builds a universal (arm64 + x86_64) Release, signs it with a stable identity,
# zips universal and arm64 archives, produces EdDSA signatures with Sparkle's
# sign_update, refreshes docs/appcast.xml, writes SHA256SUMS.txt, and uploads
# everything to the matching GitHub release tag.
#
# Usage:
#   MARKETING_VERSION=1.0.10 CURRENT_PROJECT_VERSION=1222 bash Scripts/release.sh
#
# Env:
#   MARKETING_VERSION        Required. Marketing version, e.g. 1.0.3.
#   CURRENT_PROJECT_VERSION  Required. Build number (CFBundleVersion), e.g. 1214.
#   FLOEBAR_SIGN_ID          Optional. Keychain identity for codesign. Defaults
#                            to "FloeBar Self-Signed". Keep the same certificate
#                            across releases for a stable signing requirement.
#   FLOEBAR_SKIP_UPLOAD      Optional. Set to 1 to build + sign + refresh the
#                            appcast without creating/uploading the GitHub
#                            release (dry run).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${ICE_BUILD_ROOT:-$ROOT/build/release}"
DERIVED="$BUILD_ROOT/DerivedData"
DEST="$BUILD_ROOT/dist"
RELEASE_BUNDLE_ID="com.evanzhu.FloeBar"
SPARKLE_BIN="$ROOT/build/local/SourcePackages/artifacts/sparkle/Sparkle/bin"

VERSION="${MARKETING_VERSION:?set MARKETING_VERSION, e.g. 1.0.1}"
BUILD_NUMBER="${CURRENT_PROJECT_VERSION:?set CURRENT_PROJECT_VERSION, e.g. 1207}"
TAG="v$VERSION"
SIGN_ID="${FLOEBAR_SIGN_ID:-FloeBar Self-Signed}"

mkdir -p "$DEST"

# --- Build (universal, Release). Note: unlike build-local.sh we do NOT set
# IceLocalBuild, because a published build must be allowed to self-update. ---
xcodebuild -quiet \
    -project "$ROOT/FloeBar.xcodeproj" -scheme FloeBar -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    -clonedSourcePackagesDirPath "$ROOT/build/local/SourcePackages" \
    -jobs 4 \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO \
    PRODUCT_BUNDLE_IDENTIFIER="$RELEASE_BUNDLE_ID" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build

APP="$DEST/FloeBar.app"
rm -rf "$APP"
ditto "$DERIVED/Build/Products/Release/FloeBar.app" "$APP"
plutil -replace CFBundleIdentifier -string "$RELEASE_BUNDLE_ID" "$APP/Contents/Info.plist"

# Remove debug-map entries containing local source/object paths before signing.
# Keep the separate dSYM in DerivedData for local crash symbolication.
xcrun strip -S "$APP/Contents/MacOS/FloeBar"

# Guard: a published build must carry a real SUPublicEDKey, or Sparkle can never
# verify the very updates this pipeline signs.
PUBKEY="$(plutil -extract SUPublicEDKey raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$PUBKEY" || "$PUBKEY" == "REPLACE_WITH_SUPUBLICEDKEY" ]]; then
    echo "error: SUPublicEDKey missing in Info.plist. Run generate_keys and paste the public key first." >&2
    exit 1
fi

sign_bundle() {
    local target="$1"
    local sparkle="$target/Contents/Frameworks/Sparkle.framework"
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
            echo "error: bundle contains a Mach-O file without arm64 support: $binary" >&2
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

# --- Universal zip ---
UNIVERSAL_ZIP="$DEST/FloeBar-$VERSION-universal.zip"
rm -f "$UNIVERSAL_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UNIVERSAL_ZIP"

# --- arm64-only zip (thin the universal app) ---
ARM_APP="$DEST/FloeBar-arm64.app"
rm -rf "$ARM_APP"
ditto "$APP" "$ARM_APP"
thin_bundle_to_arm64 "$ARM_APP"
sign_bundle "$ARM_APP"
ARM_ZIP="$DEST/FloeBar-$VERSION-arm64.zip"
rm -f "$ARM_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ARM_APP" "$ARM_ZIP"

# --- EdDSA signature for the universal archive (this is what Sparkle serves) ---
SIGN_OUTPUT="$("$SPARKLE_BIN/sign_update" "$UNIVERSAL_ZIP")"
# sign_update prints e.g.: sparkle:edSignature="..." length="12345"
ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGN_OUTPUT")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIGN_OUTPUT")"
if [[ -z "$ED_SIGNATURE" || -z "$LENGTH" ]]; then
    echo "error: could not parse sign_update output: $SIGN_OUTPUT" >&2
    exit 1
fi

# --- Refresh docs/appcast.xml: prepend a new <item> for this version ---
APPCAST="$ROOT/docs/appcast.xml"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
DOWNLOAD_URL="https://github.com/EvanZhuYF/FloeBar/releases/download/$TAG/FloeBar-$VERSION-universal.zip"
NEW_ITEM="        <item>
            <title>$VERSION</title>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <pubDate>$PUBDATE</pubDate>
            <enclosure
                url=\"$DOWNLOAD_URL\"
                sparkle:edSignature=\"$ED_SIGNATURE\"
                length=\"$LENGTH\"
                type=\"application/octet-stream\" />
        </item>"
# Insert the new item immediately after the first <language> line.
python3 - "$APPCAST" "$NEW_ITEM" <<'PY'
import sys
import re
path, item = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    text = f.read()
# Rebuilding an unpublished release must replace its existing feed entry.
title = re.search(r"<title>(.*?)</title>", item).group(1)
text = re.sub(
    r"        <item>\s*<title>" + re.escape(title) + r"</title>.*?</item>\n",
    "", text, flags=re.DOTALL
)
marker = "</language>\n"
idx = text.index(marker) + len(marker)
# Drop the placeholder item block if it is still present.
if "PLACEHOLDER_NOT_A_VALID_SIGNATURE" in text:
    start = text.index("        <item>")
    end = text.index("</item>", start) + len("</item>\n")
    text = text[:start] + text[end:]
    idx = text.index(marker) + len(marker)
text = text[:idx] + item + "\n" + text[idx:]
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

# --- Checksums ---
( cd "$DEST" && shasum -a 256 "FloeBar-$VERSION-universal.zip" "FloeBar-$VERSION-arm64.zip" > SHA256SUMS.txt )

echo "Built and signed:"
echo "  $UNIVERSAL_ZIP"
echo "  $ARM_ZIP"
echo "  appcast: $APPCAST (item for $VERSION added)"
echo "  checksums: $DEST/SHA256SUMS.txt"

if [[ "${FLOEBAR_SKIP_UPLOAD:-0}" == "1" ]]; then
    echo "FLOEBAR_SKIP_UPLOAD=1 set: skipping GitHub release upload (dry run)."
    echo "Next: commit docs/appcast.xml and push so GitHub Pages serves the update."
    exit 0
fi

# --- Publish to GitHub Releases ---
if gh release view "$TAG" --repo EvanZhuYF/FloeBar >/dev/null 2>&1; then
    gh release upload "$TAG" \
        "$UNIVERSAL_ZIP" "$ARM_ZIP" "$DEST/SHA256SUMS.txt" \
        --repo EvanZhuYF/FloeBar --clobber
else
    gh release create "$TAG" \
        "$UNIVERSAL_ZIP" "$ARM_ZIP" "$DEST/SHA256SUMS.txt" \
        --repo EvanZhuYF/FloeBar \
        --title "FloeBar $VERSION" \
        --notes "FloeBar $VERSION"
fi

echo
echo "Release $TAG uploaded."
echo "Next: commit docs/appcast.xml and push so GitHub Pages serves the update."
