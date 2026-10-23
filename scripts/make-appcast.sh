#!/usr/bin/env bash
# Signs a release DMG with Sparkle's sign_update (EdDSA, from a private key FILE, never
# the Keychain) and adds it to appcast.xml, newest first. An item with the same build
# number is replaced, so re-running a release is safe.
#
# usage: scripts/make-appcast.sh --dmg DMG --key-file KEY --appcast APPCAST.xml \
#          --url DOWNLOAD_URL [--notes-url URL] [--app PlatyNotch.app] [--sign-update BIN]
#
#   --key-file   Sparkle private key file (base64, as exported by `generate_keys -x`)
#   --appcast    created if missing, updated in place otherwise
#   --url        where the DMG is downloaded from (the GitHub release asset)
#   --app        the app the DMG contains (default build/PlatyNotch.app): version, build
#                number and minimum macOS are read from its Info.plist
#   --sign-update  default: Sparkle's sign_update from the SwiftPM artifact
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="" KEY="" APPCAST="" URL="" NOTES="" APP="$ROOT/build/PlatyNotch.app"
SIGN_UPDATE="$ROOT/apps/mac/.build/artifacts/sparkle/Sparkle/bin/sign_update"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-h" || "$1" == "--help" ]] && { usage; exit 0; }
  [[ $# -ge 2 ]] || { usage >&2; exit 2; }
  case "$1" in
    --dmg) DMG="$2" ;;
    --key-file) KEY="$2" ;;
    --appcast) APPCAST="$2" ;;
    --url) URL="$2" ;;
    --notes-url) NOTES="$2" ;;
    --app) APP="$2" ;;
    --sign-update) SIGN_UPDATE="$2" ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift 2
done
[[ -n "$DMG" && -n "$KEY" && -n "$APPCAST" && -n "$URL" ]] || { usage >&2; exit 2; }
[[ -f "$DMG" ]] || { echo "make-appcast: no DMG at $DMG" >&2; exit 1; }
[[ -s "$KEY" ]] || { echo "make-appcast: key file $KEY is missing or empty" >&2; exit 1; }
[[ -x "$SIGN_UPDATE" ]] || { echo "make-appcast: sign_update not found at $SIGN_UPDATE (run swift build in apps/mac)" >&2; exit 1; }
[[ "$URL" == https://* ]] || { echo "make-appcast: --url must be https" >&2; exit 1; }

plist="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"

# Prints: sparkle:edSignature="…" length="…"
attrs="$("$SIGN_UPDATE" --ed-key-file "$KEY" "$DMG")"
sig="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$attrs")"
len="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$attrs")"
[[ -n "$sig" && -n "$len" ]] || { echo "make-appcast: unexpected sign_update output: $attrs" >&2; exit 1; }

python3 -I - "$APPCAST" "$VERSION" "$BUILD" "$MIN_OS" "$URL" "$sig" "$len" "$NOTES" <<'PY'
import os, sys, email.utils
import xml.etree.ElementTree as ET

path, version, build, min_os, url, sig, length, notes = sys.argv[1:]
SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", SP)
ET.register_namespace("dc", DC)

def q(tag):
    return "{%s}%s" % (SP, tag)

if os.path.exists(path):
    tree = ET.parse(path)
    rss = tree.getroot()
    channel = rss.find("channel")
else:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "PlatyNotch"
    ET.SubElement(channel, "link").text = "https://github.com/Vaibhaav-Tiwari/PlatyNotch"
    ET.SubElement(channel, "description").text = "PlatyNotch updates"
    ET.SubElement(channel, "language").text = "en"
    tree = ET.ElementTree(rss)

for old in channel.findall("item"):
    if (old.findtext(q("version")) or "").strip() == build:
        channel.remove(old)

item = ET.Element("item")
ET.SubElement(item, "title").text = "Version " + version
ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
ET.SubElement(item, q("version")).text = build
ET.SubElement(item, q("shortVersionString")).text = version
ET.SubElement(item, q("minimumSystemVersion")).text = min_os
if notes:
    ET.SubElement(item, q("releaseNotesLink")).text = notes
ET.SubElement(item, "enclosure", {
    "url": url, "type": "application/octet-stream",
    q("edSignature"): sig, "length": length,
})

children = list(channel)
first_item = next((i for i, c in enumerate(children) if c.tag == "item"), len(children))
channel.insert(first_item, item)
ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
echo "appcast: $APPCAST now offers $VERSION ($BUILD)"
