#!/usr/bin/env bash
# Idle CPU budget (plan 3b Global Constraints, C33): the app at rest, panel collapsed,
# nothing live, default widgets, must stay under 1% CPU.
#
# Builds the Go core and serves it from a throwaway PLATYNOTCH_HOME (short /tmp path:
# macOS caps socket paths at 104 bytes), starts the app against it with
# PLATYNOTCH_EXTERNAL_CORE=1 (the core's CPU is not counted), waits 10 s, samples
#   top -l 61 -s 1 -pid <app> -stats cpu
# drops the first sample (cumulative since launch) and fails if the mean of the other 60
# is above the limit. Then quits the app and the core and deletes the temp home.
#
# The notch panel is on screen for about a minute while this runs. Needs a real Mac
# session (ideally a notched M1). Not part of CI.
#
# Options:
#   --app <PlatyNotch.app>  run a bundle built by scripts/build-app.sh (its bundled
#                           mediaremote-adapter feeds now-playing) instead of the
#                           SwiftPM release executable
#   --music-fallback        no mediaremote-adapter: now-playing falls back to AppleScript
#                           polling (an idle wake every 2 s, a read every 6 s while Music or
#                           Spotify runs). Not with --app.
#   -h, --help              this help
#
# Environment: PN_PERF_LIMIT (default 1.0, percent of one core), PN_PERF_WARMUP (s,
# default 10). Without --app the release executable uses the adapter in
# build/mediaremote-adapter when build-app.sh has built it there, else the fallback.
#
# Settings: the release executable's UserDefaults domain is "PlatyNotch" (not the
# installed app's dev.platynotch.app). Widget layout and Appearance are forced to their
# defaults for this run through the volatile argument domain; nothing is written.
# Nothing touches ~/Library/Application Support/PlatyNotch.
set -euo pipefail

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  echo "usage: scripts/perf-idle.sh [--app <PlatyNotch.app>] [--music-fallback]"
}

APP_BUNDLE=""
FALLBACK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }; APP_BUNDLE="$2"; shift 2 ;;
    --music-fallback) FALLBACK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ -n "$APP_BUNDLE" && $FALLBACK -eq 1 ]]; then
  echo "--music-fallback needs the SwiftPM executable (a bundle has the adapter)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIMIT="${PN_PERF_LIMIT:-1.0}"
WARMUP="${PN_PERF_WARMUP:-10}"
SAMPLES=61   # the first is dropped

log() { echo "==> $*"; }

# cpu_seconds <pid>: CPU time the process has used so far, in seconds (ps TIME is
# [[hh:]mm:]ss.cc).
cpu_seconds() {
  ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%.2f", s }'
}

WORK=""
SERVE_PID=""
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK="$(mktemp -d /tmp/pnperf.XXXX)"
HOME_DIR="$WORK/h"
SOCKET="$WORK/n.sock"
mkdir -p "$HOME_DIR/user"
touch "$HOME_DIR/onboarding-done"   # no onboarding window: the app starts at rest

log "building core: $WORK/notch"
(cd "$ROOT/core" && go build -o "$WORK/notch" ./cmd/notch)

if [[ -n "$APP_BUNDLE" ]]; then
  APP_BIN="$APP_BUNDLE/Contents/MacOS/PlatyNotch"
  [[ -x "$APP_BIN" ]] || { echo "no executable at $APP_BIN" >&2; exit 1; }
  MUSIC="bundled mediaremote-adapter"
else
  log "swift build (release)"
  (cd "$ROOT/apps/mac" && swift build -c release --product PlatyNotch)
  APP_BIN="$(cd "$ROOT/apps/mac" && swift build -c release --show-bin-path)/PlatyNotch"
  ADAPTER_DIR="$ROOT/build/mediaremote-adapter"
  if [[ $FALLBACK -eq 0 && -f "$ADAPTER_DIR/mediaremote-adapter.pl" ]]; then
    export PLATYNOTCH_MEDIAREMOTE_DIR="$ADAPTER_DIR"
    MUSIC="mediaremote-adapter from $ADAPTER_DIR"
  else
    unset PLATYNOTCH_MEDIAREMOTE_DIR
    MUSIC="AppleScript fallback"
  fi
fi

PLAYERS=()
for p in Music Spotify; do
  if pgrep -x "$p" >/dev/null 2>&1; then PLAYERS+=("$p"); fi
done
if [[ ${#PLAYERS[@]} -gt 0 ]]; then RUNNING="${PLAYERS[*]}"; else RUNNING="none"; fi

export PLATYNOTCH_HOME="$HOME_DIR" PLATYNOTCH_SOCKET="$SOCKET"
export PLATYNOTCH_USER_HOME="$HOME_DIR/user"   # the core never touches your real ~/.claude

log "notch serve (home $HOME_DIR)"
"$WORK/notch" serve >"$WORK/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 100); do
  [[ -S "$SOCKET" ]] && break
  kill -0 "$SERVE_PID" 2>/dev/null || { echo "notch serve exited:"; cat "$WORK/serve.log"; exit 1; }
  sleep 0.1
done
[[ -S "$SOCKET" ]] || { echo "notch serve never listened" >&2; exit 1; }

log "app: $APP_BIN"
log "music: $MUSIC; players running: $RUNNING"
# Argument-domain defaults (volatile, never saved): default widgets and Appearance.
PLATYNOTCH_EXTERNAL_CORE=1 "$APP_BIN" \
  -widgets.layout "" -appearance.settings "" \
  -appearance.minimal NO -appearance.showOnAllDisplays NO -appearance.liveSide right \
  >"$WORK/app.log" 2>&1 &
APP_PID=$!

log "waiting ${WARMUP}s for the app to settle (keep the pointer away from the notch)"
sleep "$WARMUP"
kill -0 "$APP_PID" 2>/dev/null || { echo "the app exited:"; cat "$WORK/app.log"; exit 1; }

log "sampling: top -l $SAMPLES -s 1 -pid $APP_PID -stats cpu"
CPU_BEFORE="$(cpu_seconds "$APP_PID")"
START="$(date +%s)"
VALUES="$(top -l "$SAMPLES" -s 1 -pid "$APP_PID" -stats cpu | awk '/^%CPU/ { getline; print $1 }')"
kill -0 "$APP_PID" 2>/dev/null || { echo "the app exited while sampled:"; cat "$WORK/app.log"; exit 1; }
CPU_AFTER="$(cpu_seconds "$APP_PID")"
ELAPSED=$(( $(date +%s) - START ))
# Cross-check from the process's own CPU time over the whole sampling window.
CROSS="$(awk -v a="$CPU_BEFORE" -v b="$CPU_AFTER" -v t="$ELAPSED" \
  'BEGIN { printf "%.2f s of CPU in %d s (%.3f%%)", b - a, t, (t > 0 ? 100 * (b - a) / t : 0) }')"

COUNT="$(printf '%s\n' "$VALUES" | grep -c . || true)"
if [[ "$COUNT" -lt 2 ]]; then
  echo "top returned $COUNT samples" >&2
  exit 1
fi
# Drop the first sample (cumulative since launch).
STATS="$(printf '%s\n' "$VALUES" | tail -n +2 | awk '
  { n++; s += $1; if (n == 1 || $1 > max) max = $1; if (n == 1 || $1 < min) min = $1 }
  END { printf "%d %.3f %.1f %.1f", n, s / n, min, max }')"
read -r N MEAN MIN MAX <<<"$STATS"

echo
echo "samples: $N (first dropped)  mean: ${MEAN}%  min: ${MIN}%  max: ${MAX}%  limit: ${LIMIT}%"
echo "cross-check (ps): $CROSS"
echo "music: $MUSIC; players running: $RUNNING"
if awk -v m="$MEAN" -v l="$LIMIT" 'BEGIN { exit !(m > l) }'; then
  echo "FAIL: idle CPU mean ${MEAN}% is above ${LIMIT}%"
  exit 1
fi
echo "PASS: idle CPU mean ${MEAN}% is within ${LIMIT}%"
