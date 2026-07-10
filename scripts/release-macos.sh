#!/usr/bin/env bash
#
# Build, sign, notarize and package Plate.app as a distributable DMG.
#
# The GitHub Actions release job does the same thing (.github/workflows/build.yml);
# this script exists so a release can be cut — or debugged — from a laptop
# without pushing a tag.
#
# Prerequisites:
#   * A "Developer ID Application" certificate in the login keychain.
#     (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + )
#   * App Store Connect API key credentials for notarytool, supplied either as
#     a saved keychain profile or as the three NOTARY_* variables below.
#
# Environment:
#   SIGN_IDENTITY     Codesigning identity. Default: the first "Developer ID
#                     Application" identity found in the keychain.
#   NOTARY_PROFILE    Name of a `notarytool store-credentials` keychain profile.
#                     Takes precedence over the NOTARY_KEY* variables.
#   NOTARY_KEY        Path to the App Store Connect API .p8 private key.
#   NOTARY_KEY_ID     The key's Key ID.
#   NOTARY_ISSUER_ID  The key's Issuer ID.
#
# Usage:
#   scripts/release-macos.sh [--arch arm64|x86_64] [--skip-notarize]
#
#   --skip-notarize produces a signed-but-unnotarized DMG. Useful to check the
#   signing half of the pipeline without burning a notarization round-trip;
#   the result will still be blocked by Gatekeeper on other people's machines.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
SKIP_NOTARIZE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "unsupported --arch: $ARCH (expected arm64 or x86_64)" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- identity ---

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi

if [ -z "$SIGN_IDENTITY" ]; then
    cat >&2 <<'EOF'
No "Developer ID Application" identity found in the keychain.

Create one in Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage
Certificates ▸ + ▸ Developer ID Application, then re-run. An "Apple
Development" certificate is NOT enough — it can't be notarized and macOS
will refuse to launch the result on any machine but yours.
EOF
    exit 1
fi

echo "==> Signing identity: $SIGN_IDENTITY"

# notarytool takes either a stored keychain profile or the raw API key triple.
NOTARY_ARGS=()
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
        NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    else
        echo "No notarization credentials: set NOTARY_PROFILE, or all of NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER_ID." >&2
        echo "(Or pass --skip-notarize to build a signed-only DMG.)" >&2
        exit 1
    fi
fi

# ------------------------------------------------------------------- build ---

BUILD_DIR="$REPO_ROOT/PlateApp/build"
PRODUCTS="$BUILD_DIR/Build/Products/Release"
DIST="$REPO_ROOT/dist"
APP="$PRODUCTS/Plate.app"

echo "==> Generating Xcode project"
( cd "$REPO_ROOT/PlateApp" && xcodegen generate )

# Release builds start clean. Reusing DerivedData across a change of signing
# identity re-signs the nested Plate_PlateCore.bundle without re-signing the
# .app around it, and the outer seal then fails verification with "a sealed
# resource is missing or invalid".
echo "==> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"

echo "==> Building Release ($ARCH)"
(
    cd "$REPO_ROOT/PlateApp"
    set -o pipefail
    xcodebuild \
        -project PlateApp.xcodeproj \
        -scheme PlateApp \
        -configuration Release \
        -derivedDataPath build \
        -destination 'platform=macOS' \
        ARCHS="$ARCH" \
        ONLY_ACTIVE_ARCH=NO \
        build \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
        CODE_SIGN_STYLE=Manual \
        ENABLE_HARDENED_RUNTIME=YES \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        | { command -v xcbeautify >/dev/null && xcbeautify || cat; }
)

# ------------------------------------------------------------------ verify ---

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# The hardened runtime is a hard requirement for notarization, and
# get-task-allow is a hard *dis*qualifier. Catching these here turns a ~5
# minute round-trip into an instant failure.
#
# Both outputs are captured before grepping rather than piped into it: under
# `pipefail`, `grep -q` exits on its first match, codesign takes a SIGPIPE, and
# the pipeline reports 141 even though the match succeeded. `codesign -dvvv`
# writes enough to trip this every time; the entitlements output is small
# enough that it happens not to today. Whether it fires depends on output size
# against the pipe buffer, and for the get-task-allow check it would fail
# *open* — so neither is piped.
#
# Note the -dvvv: the CodeDirectory "flags=" line only appears at verbosity 3.
SIGNATURE="$(codesign -dvvv "$APP" 2>&1)"
if ! printf '%s\n' "$SIGNATURE" | grep -qE "flags=[^ ]*runtime"; then
    echo "!! The app is not signed with the hardened runtime." >&2
    exit 1
fi

ENTITLEMENTS="$(codesign --display --entitlements :- "$APP" 2>/dev/null || true)"
if printf '%s\n' "$ENTITLEMENTS" | grep -q "get-task-allow"; then
    echo "!! The app carries get-task-allow; notarization will reject it." >&2
    exit 1
fi

# ------------------------------------------------------- notarize the .app ---

mkdir -p "$DIST"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    ZIP="$(mktemp -d)/Plate.zip"
    # ditto, not zip: it preserves the bundle's extended attributes and symlinks.
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "==> Notarizing Plate.app (this takes a few minutes)"
    xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

    # Staple the ticket onto the .app itself, not just the DMG. Once a user
    # drags the app out of the DMG the disk image's ticket no longer applies,
    # and without its own ticket a first launch offline would be refused.
    echo "==> Stapling the ticket to Plate.app"
    xcrun stapler staple "$APP"
fi

# ------------------------------------------------------------- package DMG ---

DMG="$DIST/Plate-macos-$ARCH.dmg"
STAGE="$(mktemp -d)"

cp -R "$APP" "$STAGE/Plate.app"
# The conventional drag-to-install layout. A background image and window
# geometry would need `create-dmg`; this is the no-extra-dependency version.
ln -s /Applications "$STAGE/Applications"

echo "==> Building $(basename "$DMG")"
rm -f "$DMG"
hdiutil create \
    -volname "Plate" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Signing the DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    # The DMG is a separate distributable artifact from the .app inside it, so
    # it needs its own notarization pass and its own stapled ticket.
    echo "==> Notarizing the DMG"
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$DMG"

    echo "==> Gatekeeper assessment"
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
fi

shasum -a 256 "$DMG" > "$DMG.sha256"

echo
echo "Done: $DMG"
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "NOTE: --skip-notarize — this DMG is signed but NOT notarized, so Gatekeeper will block it."
fi
