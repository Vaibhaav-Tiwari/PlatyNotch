#!/usr/bin/env bash
# Tests scripts/make-appcast.sh with a throwaway Ed25519 key made by openssl in a temp dir
# (never the Keychain): the enclosure signature verifies against the key's public half,
# a rerun of the same build replaces its item, a newer build is added first.
# Needs macOS (Sparkle's sign_update; run `swift build` in apps/mac first) and openssl 3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIGN_UPDATE="$ROOT/apps/mac/.build/artifacts/sparkle/Sparkle/bin/sign_update"
OPENSSL="$(command -v openssl)"
if [[ ! -x "$SIGN_UPDATE" ]]; then echo "skip: no sign_update (swift build in apps/mac)"; exit 0; fi
if ! "$OPENSSL" genpkey -algorithm ed25519 -out /dev/null 2>/dev/null; then
  if [[ -x /opt/homebrew/bin/openssl ]]; then OPENSSL=/opt/homebrew/bin/openssl; else echo "skip: openssl without ed25519"; exit 0; fi
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pn-appcast-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
# expect DESCRIPTION FAILURE_DETAIL -- test command...
expect() {
  local desc="$1" detail="$2"; shift 3
  if "$@"; then echo "ok   $desc"; else fail "$desc: $detail"; fi
}

# Key: 32-byte Ed25519 seed, base64 (Sparkle's exported private key format).
"$OPENSSL" genpkey -algorithm ed25519 -outform DER -out "$TMP/key.der"
tail -c 32 "$TMP/key.der" | base64 >"$TMP/sparkle_key"
"$OPENSSL" pkey -inform DER -in "$TMP/key.der" -pubout -out "$TMP/pub.pem"

fake_app() {  # fake_app VERSION BUILD
  mkdir -p "$TMP/PlatyNotch.app/Contents"
  cat >"$TMP/PlatyNotch.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$1</string>
<key>CFBundleVersion</key><string>$2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
}

run() {  # run DMG_CONTENT
  printf '%s' "$1" >"$TMP/PlatyNotch.dmg"
  "$ROOT/scripts/make-appcast.sh" --dmg "$TMP/PlatyNotch.dmg" --key-file "$TMP/sparkle_key" \
    --appcast "$TMP/appcast.xml" --app "$TMP/PlatyNotch.app" \
    --url "https://github.com/Vaibhaav-Tiwari/PlatyNotch/releases/download/v$2/PlatyNotch-$2.dmg" \
    --notes-url "https://github.com/Vaibhaav-Tiwari/PlatyNotch/releases/tag/v$2" >/dev/null
}

fake_app 0.1.0 10
run "first image" 0.1.0
run "first image, rebuilt" 0.1.0
count="$(grep -c '<item>' "$TMP/appcast.xml")"
expect "same build replaces its item" "$count items" -- test "$count" = 1

fake_app 0.2.0 12
run "second image" 0.2.0
python3 -I - "$TMP/appcast.xml" >"$TMP/items" <<'PY'
import sys, xml.etree.ElementTree as ET
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for item in ET.parse(sys.argv[1]).getroot().find("channel").findall("item"):
    enc = item.find("enclosure")
    print(item.findtext(SP + "version"), item.findtext(SP + "shortVersionString"),
          enc.get("length"), enc.get(SP + "edSignature"), enc.get("url"))
PY
first="$(head -n 1 "$TMP/items")"
expect "newer build added" "$(cat "$TMP/items")" -- test "$(wc -l <"$TMP/items" | tr -d ' ')" = 2
expect "newest first, version/build/length" "$first" -- test "${first% * *}" = "12 0.2.0 12"
expect "enclosure url" "$first" -- test "${first##* }" = \
  "https://github.com/Vaibhaav-Tiwari/PlatyNotch/releases/download/v0.2.0/PlatyNotch-0.2.0.dmg"

read -r _ _ _ sig _ <<<"$first"
base64 -d <<<"$sig" >"$TMP/sig.bin"
if "$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/PlatyNotch.dmg" -sigfile "$TMP/sig.bin" >/dev/null; then
  echo "ok   EdDSA signature verifies with the public key"
else
  fail "signature does not verify"
fi
expect "minimum macOS" "no minimumSystemVersion 15.0" -- grep -q 'minimumSystemVersion>15.0<' "$TMP/appcast.xml"

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
