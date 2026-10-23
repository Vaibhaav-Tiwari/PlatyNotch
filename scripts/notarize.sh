#!/usr/bin/env bash
# Notarizes and staples a Developer ID signed .dmg, .zip or .app with an App Store
# Connect API key:
#   AC_API_KEY_ID    key id
#   AC_API_ISSUER    issuer id
#   AC_API_KEY_PATH  path to the AuthKey_<id>.p8 file
# Without all three it logs that notarization is skipped and exits 0 (v0.1 releases are
# ad-hoc signed and not notarized). An ad-hoc signed input is refused: Apple rejects it.
#
# usage: scripts/notarize.sh PATH
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: scripts/notarize.sh PATH(.dmg|.zip|.app)" >&2; exit 2; }
TARGET="${1%/}"
[[ -e "$TARGET" ]] || { echo "notarize: $TARGET not found" >&2; exit 1; }

if [[ -z "${AC_API_KEY_ID:-}" || -z "${AC_API_ISSUER:-}" || -z "${AC_API_KEY_PATH:-}" ]]; then
  echo "notarize: skipped (AC_API_KEY_ID, AC_API_ISSUER and AC_API_KEY_PATH are not all set)"
  exit 0
fi
[[ -f "$AC_API_KEY_PATH" ]] || { echo "notarize: AC_API_KEY_PATH $AC_API_KEY_PATH is not a file" >&2; exit 1; }

signed_app="$TARGET"
[[ "$TARGET" == *.app ]] || signed_app=""
if [[ -n "$signed_app" ]] && codesign -dv "$signed_app" 2>&1 | grep -q 'Signature=adhoc'; then
  echo "notarize: $TARGET is ad-hoc signed; build with scripts/build-app.sh --sign first" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/platynotch-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SUBMIT="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  SUBMIT="$WORK/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

echo "notarize: submitting $(basename "$SUBMIT")"
xcrun notarytool submit "$SUBMIT" --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" \
  --issuer "$AC_API_ISSUER" --wait --timeout 30m --output-format json >"$WORK/result.json"
status="$(plutil -extract status raw -o - "$WORK/result.json" 2>/dev/null || echo unknown)"
id="$(plutil -extract id raw -o - "$WORK/result.json" 2>/dev/null || echo "")"
echo "notarize: $status ($id)"
if [[ "$status" != "Accepted" ]]; then
  if [[ -n "$id" ]]; then
    xcrun notarytool log "$id" --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" \
      --issuer "$AC_API_ISSUER" || true
  fi
  exit 1
fi

if [[ "$TARGET" != *.zip ]]; then   # a zip cannot be stapled; staple what it contained
  xcrun stapler staple "$TARGET"
  xcrun stapler validate "$TARGET"
fi
