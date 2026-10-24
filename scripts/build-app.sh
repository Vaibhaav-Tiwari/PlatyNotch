#!/usr/bin/env bash
# Builds build/PlatyNotch.app (arm64): the SwiftPM app, the Go core as
# Contents/MacOS/notch, Sparkle.framework, mediaremote-adapter, the PlatyNotchUI resource
# bundle (sounds), licenses, Info.plist.
#
# Signing, inside out (adapter, notch, Sparkle's XPC services and helpers, Sparkle, app):
#   default            ad-hoc (`codesign -s -`), no hardened runtime. This is what v0.1
#                      ships: macOS says it cannot verify the developer on first open.
#   --sign "<identity>" a Developer ID Application identity from the keychain search list,
#                      with the hardened runtime, a secure timestamp and
#                      apps/mac/Resources/PlatyNotch.entitlements (then scripts/notarize.sh).
#
# Environment:
#   SPARKLE_ED_PUBLIC_KEY  Sparkle EdDSA public key for SUPublicEDKey; empty (default)
#                          turns Sparkle updates off in the app.
#   BUILD_NUMBER           CFBundleVersion override (see scripts/version.sh)
#   PLATYNOTCH_BUILD_DIR   output directory (default: build/ in the repo)
#
# The mediaremote-adapter build is cached in $PLATYNOTCH_BUILD_DIR/mediaremote-adapter;
# --refresh-adapter rebuilds it (scripts/fetch-mediaremote-adapter.sh, needs cmake).
set -euo pipefail

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  echo "usage: scripts/build-app.sh [--sign \"Developer ID Application: …\"] [--refresh-adapter]"
}

IDENTITY=""
REFRESH_ADAPTER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }; IDENTITY="$2"; shift 2 ;;
    --refresh-adapter) REFRESH_ADAPTER=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${PLATYNOTCH_BUILD_DIR:-$ROOT/build}"
APP="$OUT/PlatyNotch.app"
ADAPTER_CACHE="$OUT/mediaremote-adapter"
RES_SRC="$ROOT/apps/mac/Resources"
ARCH=arm64

log() { echo "==> $*"; }

read -r VERSION BUILD < <("$ROOT/scripts/version.sh")
log "PlatyNotch $VERSION ($BUILD), $ARCH, $( [[ -n "$IDENTITY" ]] && echo "signed: $IDENTITY" || echo "ad-hoc signed" )"
mkdir -p "$OUT"

# --- Build -------------------------------------------------------------------------------
log "swift build (release, $ARCH)"
(cd "$ROOT/apps/mac" && swift build -c release --arch "$ARCH")
SWIFT_BIN="$(cd "$ROOT/apps/mac" && swift build -c release --arch "$ARCH" --show-bin-path)"
SPARKLE_ARTIFACT="$ROOT/apps/mac/.build/artifacts/sparkle/Sparkle"

if [[ $REFRESH_ADAPTER -eq 1 || ! -f "$ADAPTER_CACHE/mediaremote-adapter.pl" ]]; then
  log "mediaremote-adapter"
  "$ROOT/scripts/fetch-mediaremote-adapter.sh" "$ADAPTER_CACHE" "$OUT/mediaremote-adapter-build"
fi

# --- Assemble ----------------------------------------------------------------------------
log "assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

log "go build notch"
(cd "$ROOT/core" && CGO_ENABLED=0 GOOS=darwin GOARCH="$ARCH" go build -trimpath \
  -ldflags "-s -w -X github.com/Vaibhaav-Tiwari/PlatyNotch/core/cli.Version=$VERSION" \
  -o "$APP/Contents/MacOS/notch" ./cmd/notch)

cp "$SWIFT_BIN/PlatyNotch" "$APP/Contents/MacOS/PlatyNotch"
# SwiftPM links with @loader_path (Contents/MacOS); Sparkle lives in Contents/Frameworks.
# Toolchain rpaths (/Applications/Xcode.app/…) are build-machine paths: drop them.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PlatyNotch"
while read -r rp; do
  install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/PlatyNotch"
done < <(otool -l "$APP/Contents/MacOS/PlatyNotch" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -E '^/Applications/|\.xctoolchain/' || true)

ditto "$SWIFT_BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle ships universal; keep arm64 only (every notched Mac is Apple silicon).
while IFS= read -r -d '' f; do
  if archs="$(lipo -archs "$f" 2>/dev/null)" && [[ "$archs" == *" "* ]]; then
    lipo -thin "$ARCH" "$f" -output "$f.thin" && mv "$f.thin" "$f"
  fi
done < <(find "$APP/Contents/Frameworks/Sparkle.framework" -type f -perm -u+x -print0)

ditto "$ADAPTER_CACHE" "$APP/Contents/Resources/mediaremote-adapter"

cp "$RES_SRC/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -replace SUPublicEDKey -string "${SPARKLE_ED_PUBLIC_KEY:-}" "$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"
# App icon hook (Plan 3b): copied when present; CFBundleIconFile names it either way.
[[ -f "$RES_SRC/AppIcon.icns" ]] && cp "$RES_SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundle (sounds). SwiftPM writes a flat folder, which codesign cannot
# sign ("bundle format unrecognized"), so it becomes a real bundle (Contents/Info.plist,
# Contents/Resources). PlatyNotchUI's UIResources looks for it in Contents/Resources.
RES_BUNDLE_NAME=PlatyNotch_PlatyNotchUI.bundle
RES_BUNDLE="$APP/Contents/Resources/$RES_BUNDLE_NAME"
[[ -d "$SWIFT_BIN/$RES_BUNDLE_NAME" ]] || { echo "missing $SWIFT_BIN/$RES_BUNDLE_NAME" >&2; exit 1; }
if [[ -f "$SWIFT_BIN/$RES_BUNDLE_NAME/Contents/Info.plist" ]]; then
  ditto "$SWIFT_BIN/$RES_BUNDLE_NAME" "$RES_BUNDLE"
else
  mkdir -p "$RES_BUNDLE/Contents/Resources"
  ditto "$SWIFT_BIN/$RES_BUNDLE_NAME" "$RES_BUNDLE/Contents/Resources"
  cat >"$RES_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.platynotch.app.resources.ui</string>
  <key>CFBundleName</key><string>PlatyNotch_PlatyNotchUI</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
</dict>
</plist>
PLIST
fi

cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$APP/Contents/Resources/"
cp "$ROOT/third_party/mediaremote-adapter-LICENSE" "$APP/Contents/Resources/mediaremote-adapter-LICENSE"
cp "$SPARKLE_ARTIFACT/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"

# --- Sign (inside out) -------------------------------------------------------------------
if [[ -n "$IDENTITY" ]]; then
  SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
else
  SIGN=(codesign --force --sign - --timestamp=none)
fi
sign() { "${SIGN[@]}" "$@"; }

log "codesign"
ADAPTER="$APP/Contents/Resources/mediaremote-adapter"
sign "$ADAPTER/MediaRemoteAdapterTestClient"
sign "$ADAPTER/MediaRemoteAdapter.framework"
sign "$APP/Contents/MacOS/notch"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for xpc in "$SPARKLE"/XPCServices/*.xpc; do
  # Downloader.xpc carries its own (sandbox / network) entitlements.
  sign --preserve-metadata=entitlements "$xpc"
done
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$RES_BUNDLE"

if [[ -n "$IDENTITY" ]]; then
  sign --entitlements "$RES_SRC/PlatyNotch.entitlements" "$APP"
else
  sign "$APP"
fi

# --- Check -------------------------------------------------------------------------------
plutil -lint "$APP/Contents/Info.plist" "$RES_BUNDLE/Contents/Info.plist" >/dev/null
for snd in alarm chime; do   # scripts/make-sounds.py
  [[ -f "$RES_BUNDLE/Contents/Resources/$snd.wav" ]] || { echo "missing sound $snd.wav in $RES_BUNDLE" >&2; exit 1; }
done
codesign --verify --strict "$RES_BUNDLE"
codesign --verify --deep --strict "$APP"
log "done: $APP ($VERSION, build $BUILD; updates $( [[ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]] && echo on || echo off ))"
