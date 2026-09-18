#!/bin/bash
#
# sign-with-selfsigned.sh — sign an existing FloeBar.app with the local
# "FloeBar Self-Signed" certificate so macOS keeps previously granted
# Accessibility / Screen Recording permissions across reinstalls.
#
# WHY THIS IS A SEPARATE, INTERACTIVE SCRIPT:
# codesign needs to read the certificate's private key from your login
# keychain. The first time, macOS shows a keychain prompt — you must click
# "Always Allow". That prompt can only appear in YOUR OWN Terminal, not in an
# automated/non-interactive shell. Run this once in Terminal; after clicking
# "Always Allow", future signings (including build-local.sh) run without prompts.
#
# Usage:
#   bash Scripts/sign-with-selfsigned.sh /path/to/FloeBar.app
#
set -euo pipefail

APP="${1:?Usage: sign-with-selfsigned.sh /path/to/FloeBar.app}"
IDENTITY="FloeBar Self-Signed"

if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    printf 'ERROR: certificate "%s" not found in your keychain.\n' "$IDENTITY" >&2
    printf 'Create it first (see rebrand-07-self-signed-codesign.md).\n' >&2
    exit 1
fi

# Sign inside-out: nested Sparkle components first, then the app.
MENU_BAR_SERVICE="$APP/Contents/XPCServices/MenuBarItemService.xpc"
MENU_BAR_SERVICE_ID="$(plutil -extract CFBundleIdentifier raw -o - \
    "$MENU_BAR_SERVICE/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$MENU_BAR_SERVICE_ID" != "com.evanzhu.FloeBar.MenuBarItemService" ]]; then
    printf 'ERROR: missing or incorrectly identified MenuBarItemService.xpc: %s\n' \
        "$MENU_BAR_SERVICE_ID" >&2
    exit 1
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$MENU_BAR_SERVICE"
CAPTURE_SERVICE="$APP/Contents/XPCServices/MenuBarCaptureService.xpc"
CAPTURE_SERVICE_ID="$(plutil -extract CFBundleIdentifier raw -o - \
    "$CAPTURE_SERVICE/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$CAPTURE_SERVICE_ID" != "com.evanzhu.FloeBar.MenuBarCaptureService" ]]; then
    printf 'ERROR: missing or incorrectly identified MenuBarCaptureService.xpc: %s\n' \
        "$CAPTURE_SERVICE_ID" >&2
    exit 1
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$CAPTURE_SERVICE"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    for COMPONENT in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app" \
        "$SPARKLE/Versions/B/Sparkle" \
        "$SPARKLE"; do
        codesign --force --sign "$IDENTITY" --timestamp=none "$COMPONENT"
    done
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
printf '\nSigned with "%s":\n' "$IDENTITY"
codesign -dvv "$APP" 2>&1 | grep -iE 'Authority|Identifier|Signature'
printf '\nDone. Reinstall this app; macOS should keep its previous permissions.\n'
