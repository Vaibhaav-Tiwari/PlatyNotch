#!/usr/bin/env bash
# Tests scripts/version.sh against throwaway git repos. Run: scripts/tests/version_test.sh
set -euo pipefail

VERSION_SH="$(cd "$(dirname "$0")/.." && pwd)/version.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pn-version-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0

# check NAME EXPECTED -- command...
check() {
  local name="$1" want="$2"; shift 3
  local got
  got="$("$@" 2>/dev/null)" || got="<exit $?>"
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: got '$got', want '$want'"; fails=$((fails + 1))
  fi
}

repo() {  # repo DIR COMMITS -> a git repo with COMMITS empty commits
  local d="$1" n="$2" i
  git init -q "$d"
  for ((i = 1; i <= n; i++)); do
    git -C "$d" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m "c$i"
  done
}

repo "$TMP/plain" 3
check "default without tag or VERSION" "0.1.0 3" -- env -u BUILD_NUMBER "$VERSION_SH" "$TMP/plain"

repo "$TMP/file" 2
printf '0.4.2\n' >"$TMP/file/VERSION"
check "VERSION file" "0.4.2 2" -- env -u BUILD_NUMBER "$VERSION_SH" "$TMP/file"

repo "$TMP/tag" 5
printf '0.4.2\n' >"$TMP/tag/VERSION"
git -C "$TMP/tag" tag v1.2.3
check "exact v tag wins over VERSION" "1.2.3 5" -- env -u BUILD_NUMBER "$VERSION_SH" "$TMP/tag"
check "BUILD_NUMBER overrides the commit count" "1.2.3 77" -- env BUILD_NUMBER=77 "$VERSION_SH" "$TMP/tag"

git -C "$TMP/tag" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m after
check "tag not at HEAD is ignored" "0.4.2 6" -- env -u BUILD_NUMBER "$VERSION_SH" "$TMP/tag"

repo "$TMP/bad" 1
git -C "$TMP/bad" tag v1.2.3-beta
check "non-numeric v tag fails" "<exit 1>" -- env -u BUILD_NUMBER "$VERSION_SH" "$TMP/bad"

repo "$TMP/badfile" 1
printf 'one\n' >"$TMP/badfile/VERSION"
check "malformed VERSION fails" "<exit 1>" -- env -u BUILD_NUMBER "$VERSION_SH" "$TMP/badfile"
check "non-numeric BUILD_NUMBER fails" "<exit 1>" -- env BUILD_NUMBER=x "$VERSION_SH" "$TMP/plain"

mkdir "$TMP/nogit"
check "outside git: build 1" "0.1.0 1" -- env -u BUILD_NUMBER "$VERSION_SH" "$TMP/nogit"

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
