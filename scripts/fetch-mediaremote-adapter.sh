#!/usr/bin/env bash
# Fetches and builds mediaremote-adapter (BSD-3-Clause, github.com/ungive/mediaremote-adapter)
# at a pinned tag, for the Now Playing view. Its source and binaries are not committed:
# the packaging step runs this and copies OUT_DIR into the app as
# Contents/Resources/mediaremote-adapter/.
#
# OUT_DIR receives:
#   MediaRemoteAdapter.framework      (bundled, never linked)
#   MediaRemoteAdapterTestClient      (for the adapter's `test` command)
#   mediaremote-adapter.pl            (run with /usr/bin/perl)
#   LICENSE                           (the adapter's BSD-3-Clause license)
#
# For a dev run: PLATYNOTCH_MEDIAREMOTE_DIR=OUT_DIR swift run PlatyNotch
set -euo pipefail

REPO="https://github.com/ungive/mediaremote-adapter.git"
TAG="v0.7.7"
COMMIT="e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6"   # what $TAG pointed to when pinned

usage() {
  echo "usage: scripts/fetch-mediaremote-adapter.sh OUT_DIR [BUILD_DIR]" >&2
  echo "  BUILD_DIR defaults to \${TMPDIR:-/tmp}/platynotch-mediaremote-adapter" >&2
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
[[ "$1" == "-h" || "$1" == "--help" ]] && { usage; exit 0; }

OUT_DIR="$1"
BUILD_DIR="${2:-${TMPDIR:-/tmp}/platynotch-mediaremote-adapter}"

CMAKE="$(command -v cmake || true)"
[[ -z "$CMAKE" && -x /opt/homebrew/bin/cmake ]] && CMAKE=/opt/homebrew/bin/cmake
[[ -z "$CMAKE" && -x /usr/local/bin/cmake ]] && CMAKE=/usr/local/bin/cmake
[[ -n "$CMAKE" ]] || { echo "cmake not found (brew install cmake)" >&2; exit 1; }

SRC="$BUILD_DIR/src"
rm -rf "$SRC" "$BUILD_DIR/build"
mkdir -p "$BUILD_DIR"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" "$REPO" "$SRC"
actual="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$actual" != "$COMMIT" ]]; then
  echo "mediaremote-adapter $TAG is $actual, expected $COMMIT; refusing to build" >&2
  exit 1
fi

"$CMAKE" -S "$SRC" -B "$BUILD_DIR/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
"$CMAKE" --build "$BUILD_DIR/build" --config Release >/dev/null

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/MediaRemoteAdapter.framework"
cp -R "$BUILD_DIR/build/MediaRemoteAdapter.framework" "$OUT_DIR/"
cp "$BUILD_DIR/build/MediaRemoteAdapterTestClient" "$OUT_DIR/"
cp "$SRC/bin/mediaremote-adapter.pl" "$OUT_DIR/"
cp "$SRC/LICENSE" "$OUT_DIR/LICENSE"
echo "mediaremote-adapter $TAG ($COMMIT) -> $OUT_DIR"
