#!/usr/bin/env bash
#
# Emit a Sparkle appcast (to stdout) describing one release: the universal DMG.
#
# Sparkle picks an update by comparing the appcast's <sparkle:version>
# (CFBundleVersion) against the installed build. We read the version, the
# human-readable string, and the minimum OS straight from the built app so the
# feed can never drift from what actually shipped, then sign the DMG with the
# EdDSA key so Sparkle will trust the download.
#
# Usage:
#   scripts/make-appcast.sh <app-path> <dmg-path> <download-url> > appcast.xml
#
# Environment:
#   SPARKLE_PRIVATE_KEY   The EdDSA private key (base64). If unset, sign_update
#                         falls back to the key in the login keychain.
#   SIGN_UPDATE           Path to Sparkle's sign_update tool. If unset, it is
#                         located under the resolved SPM artifacts.
#   RELEASE_NOTES_URL     Optional URL shown as the item's release notes.

set -euo pipefail

APP="${1:?usage: make-appcast.sh <app-path> <dmg-path> <download-url>}"
DMG="${2:?missing <dmg-path>}"
URL="${3:?missing <download-url>}"

plist="$APP/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }

SHORT_VERSION="$(read_plist CFBundleShortVersionString)"
BUILD_VERSION="$(read_plist CFBundleVersion)"
MIN_OS="$(read_plist LSMinimumSystemVersion 2>/dev/null || echo "10.15")"

# Locate sign_update: honour an explicit path, otherwise take the newest one
# under the SPM artifacts (both DerivedData layouts are searched).
SIGN_UPDATE="${SIGN_UPDATE:-}"
if [ -z "$SIGN_UPDATE" ]; then
    SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        "$(dirname "$APP")/../../.." \
        -path "*artifacts/sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)"
fi
[ -x "$SIGN_UPDATE" ] || { echo "sign_update tool not found (set SIGN_UPDATE)" >&2; exit 1; }

# `sign_update` prints ready-made enclosure attributes:
#   sparkle:edSignature="…" length="…"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    SIG_ATTRS="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$DMG")"
else
    SIG_ATTRS="$("$SIGN_UPDATE" "$DMG")"
fi

NOTES_LINE=""
[ -n "${RELEASE_NOTES_URL:-}" ] && NOTES_LINE="      <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Plate</title>
    <description>Updates for Plate</description>
    <language>en</language>
    <item>
      <title>${SHORT_VERSION}</title>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <pubDate>$(date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
${NOTES_LINE}
      <enclosure url="${URL}" type="application/octet-stream" ${SIG_ATTRS} />
    </item>
  </channel>
</rss>
XML
