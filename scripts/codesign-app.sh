#!/usr/bin/env bash
#
# Deep-sign Plate.app for Developer ID distribution, Sparkle helpers included.
#
# xcodebuild signs the app and the outer Sparkle.framework, but it leaves the
# framework's *nested* helpers — Autoupdate, Updater.app, and the Downloader /
# Installer XPC services — carrying Sparkle's own signature with no secure
# timestamp. Notarization rejects exactly those (see the earlier
# "not signed with a valid Developer ID certificate" failures). codesign has to
# re-sign them with our identity, hardened runtime, and a timestamp, working
# inside-out so each enclosing seal covers the freshly-signed contents.
#
# Usage:
#   scripts/codesign-app.sh <path-to-Plate.app>
#
# Environment:
#   SIGN_IDENTITY       Developer ID Application identity (required).
#   CODESIGN_KEYCHAIN   Keychain holding the identity (optional; CI uses a
#                       throwaway keychain that isn't the default search list).

set -euo pipefail

APP="${1:?usage: codesign-app.sh <path-to-Plate.app>}"
: "${SIGN_IDENTITY:?SIGN_IDENTITY must be set}"

FW="$APP/Contents/Frameworks/Sparkle.framework"

# Common flags. --options runtime is the hardened runtime; --timestamp fetches
# a secure timestamp (both notarization preconditions). A keychain is passed
# only when the caller set one.
FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
[ -n "${CODESIGN_KEYCHAIN:-}" ] && FLAGS+=(--keychain "$CODESIGN_KEYCHAIN")

sign() {
    echo "    signing: ${1#"$APP"/}"
    codesign "${FLAGS[@]}" "$1"
}

if [ -d "$FW" ]; then
    echo "==> Re-signing Sparkle helpers inside-out"
    V="$FW/Versions/B"
    # Deepest first: XPC services, then the updater app, then the bare
    # Autoupdate tool, then the framework that encloses them all.
    for xpc in "$V/XPCServices/Downloader.xpc" "$V/XPCServices/Installer.xpc"; do
        [ -d "$xpc" ] && sign "$xpc"
    done
    [ -d "$V/Updater.app" ] && sign "$V/Updater.app"
    [ -f "$V/Autoupdate" ] && sign "$V/Autoupdate"
    sign "$FW"
fi

echo "==> Signing Plate.app"
sign "$APP"
