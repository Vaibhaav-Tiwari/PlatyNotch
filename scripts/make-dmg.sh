#!/usr/bin/env bash
# Packs PlatyNotch.app into a compressed disk image (UDZO) with an /Applications link,
# and prints the DMG path on the last line.
#
# usage: scripts/make-dmg.sh [--sign "<Developer ID Application: …>"] [APP] [OUT_DMG]
#   APP      default build/PlatyNotch.app
#   OUT_DMG  default build/PlatyNotch-<CFBundleShortVersionString>.dmg
#   --sign   also signs the image (needed before notarizing it); otherwise it is unsigned
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY=""
if [[ "${1:-}" == "--sign" ]]; then
  [[ -n "${2:-}" ]] || { echo "--sign needs an identity" >&2; exit 2; }
  IDENTITY="$2"; shift 2
fi
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

APP="${1:-$ROOT/build/PlatyNotch.app}"
[[ -d "$APP" ]] || { echo "no app at $APP (run scripts/build-app.sh)" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="${2:-$(dirname "$APP")/PlatyNotch-$VERSION.dmg}"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/platynotch-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/PlatyNotch.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "PlatyNotch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
hdiutil verify -quiet "$DMG"
echo "$DMG"
