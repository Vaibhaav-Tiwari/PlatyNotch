#!/usr/bin/env bash
# Prints "<version> <build>" for the app bundle (CFBundleShortVersionString and
# CFBundleVersion).
#
#   version: a vX.Y.Z tag at HEAD, else the VERSION file, else 0.1.0
#   build:   $BUILD_NUMBER, else the commit count of HEAD (rises with every commit on
#            main, which Sparkle compares), else 1
#
# usage: scripts/version.sh [REPO_DIR]   (default: the repository this script is in)
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
numeric='^[0-9]+\.[0-9]+\.[0-9]+$'

fail() { echo "version.sh: $*" >&2; exit 1; }

version=""
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tag="$(git -C "$DIR" tag --points-at HEAD --list 'v[0-9]*' | sort -V | tail -n 1)"
  if [[ -n "$tag" ]]; then
    version="${tag#v}"
    [[ "$version" =~ $numeric ]] || fail "tag $tag is not vMAJOR.MINOR.PATCH"
  fi
fi
if [[ -z "$version" && -f "$DIR/VERSION" ]]; then
  version="$(tr -d '[:space:]' <"$DIR/VERSION")"
  [[ "$version" =~ $numeric ]] || fail "VERSION file holds '$version', not MAJOR.MINOR.PATCH"
fi
version="${version:-0.1.0}"

if [[ -n "${BUILD_NUMBER:-}" ]]; then
  [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "BUILD_NUMBER '$BUILD_NUMBER' is not a number"
  build="$BUILD_NUMBER"
else
  build="$(git -C "$DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
fi

echo "$version $build"
