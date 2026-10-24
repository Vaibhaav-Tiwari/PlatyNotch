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
#   --app [PlatyNotch.app]  run a bundle built by scripts/build-app.sh (default
#                           build/PlatyNotch.app; its bundled mediaremote-adapter feeds
#                           now-playing) instead of the SwiftPM release executable. It runs
#                           as a copy, build/perf/PlatyNotch.app, with the bundle id
#                           dev.platynotch.perf (ad-hoc re-signed), so it never reads or
#                           writes the installed app's settings or permissions. The copy is
#                           refreshed only when the source bundle is newer, so a permission
#                           granted to it (Automation) lasts across runs.
#   --music-fallback        no mediaremote-adapter (PLATYNOTCH_NO_MEDIAREMOTE=1): now-playing
#                           falls back to AppleScript polling (an idle wake every 2 s, a read
#                           every 6 s while Music or Spotify runs). The reads need the app's
#                           Automation permission for the player: measure that with
#                           `--app --music-fallback` after granting it (verify-widgets #178).
#   --state <s>             measure with something live instead of at rest (Platy's
#                           moods; the panel stays on screen): `working` (one active
#                           Claude Code session: the pill, Platy paddling), `waiting`
#                           (a session waiting for input: the pill, Platy waiting), or
#                           `approval` (a pending permission request: the approval peek),
#                           or `music` (a fake track playing: the pill's music bars; the app
#                           gets PLATYNOTCH_FAKE_NOWPLAYING=1, honoured only with this
#                           script's --perf-run argument, and reads no player). Agent states
#                           are sent as fake hook events through the core after the warm-up.
#                           Every run reports whether a real player is playing (from the
#                           mediaremote-adapter when there is one, else "unknown"): a playing
#                           player shows the music bars and changes what is measured.
#   -h, --help              this help
#
# Environment: PN_PERF_LIMIT (default 1.0, percent of one core), PN_PERF_WARMUP (s,
# default 10), PN_PERF_VERBOSE=1 (print every sample), PN_PERF_APPEARANCE (Appearance settings as a plist data literal, e.g.
# "<7b2273686f77506c617479223a66616c73657d>" = {"showPlaty":false}; default: the defaults). Without --app the release executable uses the adapter in
# build/mediaremote-adapter when build-app.sh has built it there, else the fallback.
#
# Settings: the release executable's UserDefaults domain is "PlatyNotch", the bundle
# copy's dev.platynotch.perf (never the installed app's dev.platynotch.app). Widget layout and
# Appearance are forced to their defaults for this run through the volatile argument domain, and
# with --perf-run the app's widget registry does not persist, so widgets.layout is never written.
# Nothing touches ~/Library/Application Support/PlatyNotch.
#
# CPU: the mean is the app's own (top). The now-playing adapter runs as the app's child process
# (/usr/bin/perl); its CPU over the same window is summed from `ps` (pgrep -P) and reported,
# and the run also fails when the app and its children together are above the limit.
set -euo pipefail

usage() {
  # The whole header comment, through Environment and Settings.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  echo "usage: scripts/perf-idle.sh [--app [PlatyNotch.app]] [--music-fallback] [--state working|waiting|approval|music]"
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PLATYNOTCH_BUILD_DIR:-$ROOT/build}"
PERF_ID="dev.platynotch.perf"
APP_BUNDLE=""
FALLBACK=0
STATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      if [[ $# -ge 2 && -n "$2" && "$2" != -* ]]; then APP_BUNDLE="$2"; shift 2
      else APP_BUNDLE="$BUILD_DIR/PlatyNotch.app"; shift; fi ;;
    --music-fallback) FALLBACK=1; shift ;;
    --state)
      case "${2:-}" in working|waiting|approval|music) STATE="$2"; shift 2 ;;
        *) echo "--state needs working, waiting, approval or music" >&2; exit 2 ;; esac ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

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
HOOK_PID=""

cleanup() {
  if [[ -n "$HOOK_PID" ]] && kill -0 "$HOOK_PID" 2>/dev/null; then
    pkill -P "$HOOK_PID" 2>/dev/null || true
    kill "$HOOK_PID" 2>/dev/null || true
  fi
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$APP_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERVE_PID" ]] && kill -0 "$SERVE_PID" 2>/dev/null; then
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
  SRC_BIN="$APP_BUNDLE/Contents/MacOS/PlatyNotch"
  [[ -x "$SRC_BIN" ]] || { echo "no executable at $SRC_BIN (scripts/build-app.sh builds it)" >&2; exit 1; }
  PERF_APP="$BUILD_DIR/perf/PlatyNotch.app"
  if [[ ! -x "$PERF_APP/Contents/MacOS/PlatyNotch" || "$SRC_BIN" -nt "$PERF_APP/Contents/MacOS/PlatyNotch" ]]; then
    log "copying $APP_BUNDLE to $PERF_APP as $PERF_ID"
    rm -rf "$PERF_APP"
    mkdir -p "$(dirname "$PERF_APP")"
    ditto "$APP_BUNDLE" "$PERF_APP"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PERF_ID" "$PERF_APP/Contents/Info.plist"
    codesign --force --deep --sign - "$PERF_APP" >/dev/null
  fi
  APP_BIN="$PERF_APP/Contents/MacOS/PlatyNotch"
  ADAPTER_FOR_STATUS="$PERF_APP/Contents/Resources/mediaremote-adapter"
  unset PLATYNOTCH_MEDIAREMOTE_DIR
  if [[ $FALLBACK -eq 1 ]]; then
    export PLATYNOTCH_NO_MEDIAREMOTE=1
    MUSIC="AppleScript fallback (bundle, adapter turned off)"
  else
    unset PLATYNOTCH_NO_MEDIAREMOTE
    MUSIC="bundled mediaremote-adapter"
  fi
else
  log "swift build (release)"
  (cd "$ROOT/apps/mac" && swift build -c release --product PlatyNotch)
  APP_BIN="$(cd "$ROOT/apps/mac" && swift build -c release --show-bin-path)/PlatyNotch"
  unset PLATYNOTCH_NO_MEDIAREMOTE
  ADAPTER_DIR="$BUILD_DIR/mediaremote-adapter"
  if [[ $FALLBACK -eq 0 && -f "$ADAPTER_DIR/mediaremote-adapter.pl" ]]; then
    export PLATYNOTCH_MEDIAREMOTE_DIR="$ADAPTER_DIR"
    ADAPTER_FOR_STATUS="$ADAPTER_DIR"
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

# playing_now: whether any player is playing, from the adapter's `get` (yes / no / unknown).
playing_now() {
  local dir="${ADAPTER_FOR_STATUS:-}" out
  if [[ -z "$dir" || ! -f "$dir/mediaremote-adapter.pl" ]]; then echo "unknown"; return; fi
  out="$(/usr/bin/perl "$dir/mediaremote-adapter.pl" "$dir/MediaRemoteAdapter.framework" get 2>/dev/null || true)"
  if [[ "$out" == *'"playing":true'* ]]; then echo "yes"
  elif [[ -n "$out" ]]; then echo "no"
  else echo "unknown"; fi
}

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
FAKE_NP=0
[[ "$STATE" == music ]] && FAKE_NP=1
PLATYNOTCH_FAKE_NOWPLAYING="$FAKE_NP" PLATYNOTCH_EXTERNAL_CORE=1 "$APP_BIN" --perf-run \
  -widgets.layout "" -appearance.settings "${PN_PERF_APPEARANCE:-}" \
  -appearance.minimal NO -appearance.showOnAllDisplays NO -appearance.liveSide right \
  >"$WORK/app.log" 2>&1 &
APP_PID=$!

log "waiting ${WARMUP}s for the app to settle (keep the pointer away from the notch)"
sleep "$WARMUP"

# hook <event> <json>: one fake Claude Code hook event through the core.
hook() { printf '%s' "$2" | "$WORK/notch" hook claude-code "$1"; }
if [[ -n "$STATE" && "$STATE" != music ]]; then
  SID='"perf-1"'
  CWD="\"$WORK\""
  log "state: $STATE"
  hook session-start "{\"session_id\":$SID,\"cwd\":$CWD,\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  hook user-prompt-submit "{\"session_id\":$SID,\"cwd\":$CWD,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"perf\"}"
  case "$STATE" in
    waiting)
      hook notification "{\"session_id\":$SID,\"cwd\":$CWD,\"hook_event_name\":\"Notification\",\"notification_type\":\"agent_needs_input\",\"message\":\"perf\"}" ;;
    approval)
      # Waits for an answer that never comes; killed at the end.
      hook permission-request "{\"session_id\":$SID,\"cwd\":$CWD,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"true\",\"description\":\"perf\"},\"tool_use_id\":\"toolu_perf\"}" >/dev/null &
      HOOK_PID=$! ;;
  esac
  sleep 5   # let the panel take the new state before sampling
  "$WORK/notch" status | sed 's/^/    core: /'
fi
kill -0 "$APP_PID" 2>/dev/null || { echo "the app exited:"; cat "$WORK/app.log"; exit 1; }

# children_cpu_seconds <pid>: CPU time used so far by the direct children (the adapter).
children_cpu_seconds() {
  local total=0 c
  for c in $(pgrep -P "$1" 2>/dev/null || true); do
    total="$(awk -v a="$total" -v b="$(cpu_seconds "$c")" 'BEGIN { printf "%.2f", a + b }')"
  done
  echo "$total"
}

log "sampling: top -l $SAMPLES -s 1 -pid $APP_PID -stats cpu"
PLAYING_BEFORE="$(playing_now)"
CHILDREN_START="$(pgrep -P "$APP_PID" 2>/dev/null | tr '\n' ' ' || true)"
CPU_BEFORE="$(cpu_seconds "$APP_PID")"
KIDS_BEFORE="$(children_cpu_seconds "$APP_PID")"
START="$(date +%s)"
VALUES="$(top -l "$SAMPLES" -s 1 -pid "$APP_PID" -stats cpu | awk '/^%CPU/ { getline; print $1 }')"
kill -0 "$APP_PID" 2>/dev/null || { echo "the app exited while sampled:"; cat "$WORK/app.log"; exit 1; }
CPU_AFTER="$(cpu_seconds "$APP_PID")"
KIDS_AFTER="$(children_cpu_seconds "$APP_PID")"
CHILDREN_END="$(pgrep -P "$APP_PID" 2>/dev/null | tr '\n' ' ' || true)"
PLAYING_AFTER="$(playing_now)"
ELAPSED=$(( $(date +%s) - START ))
# A child that started or exited during the window makes the difference approximate.
KIDS="$(awk -v a="$KIDS_BEFORE" -v b="$KIDS_AFTER" -v t="$ELAPSED" \
  'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.2f %.3f", d, (t > 0 ? 100 * d / t : 0) }')"
read -r KIDS_S KIDS_PCT <<<"$KIDS"
TOTAL_PCT="$(awk -v a="$CPU_BEFORE" -v b="$CPU_AFTER" -v k="$KIDS_S" -v t="$ELAPSED" \
  'BEGIN { printf "%.3f", (t > 0 ? 100 * (b - a + k) / t : 0) }')"
# Cross-check from the process's own CPU time over the whole sampling window.
CROSS="$(awk -v a="$CPU_BEFORE" -v b="$CPU_AFTER" -v t="$ELAPSED" \
  'BEGIN { printf "%.2f s of CPU in %d s (%.3f%%)", b - a, t, (t > 0 ? 100 * (b - a) / t : 0) }')"

if [[ "${PN_PERF_VERBOSE:-0}" == 1 ]]; then
  echo "per-second samples: $(printf '%s\n' "$VALUES" | tail -n +2 | tr '\n' ' ')"
fi
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
echo "children (adapter; pids ${CHILDREN_START:-none}→ ${CHILDREN_END:-none}): ${KIDS_S} s (${KIDS_PCT}%)  app + children: ${TOTAL_PCT}%"
echo "music: $MUSIC; players running: $RUNNING"
echo "state: ${STATE:-rest}"
echo "a real player playing (adapter): before ${PLAYING_BEFORE}, after ${PLAYING_AFTER}"
if awk -v m="$MEAN" -v l="$LIMIT" 'BEGIN { exit !(m > l) }'; then
  echo "FAIL: idle CPU mean ${MEAN}% is above ${LIMIT}%"
  exit 1
fi
if awk -v m="$TOTAL_PCT" -v l="$LIMIT" 'BEGIN { exit !(m > l) }'; then
  echo "FAIL: the app and its children used ${TOTAL_PCT}%, above ${LIMIT}%"
  exit 1
fi
echo "PASS: idle CPU mean ${MEAN}% is within ${LIMIT}%"
