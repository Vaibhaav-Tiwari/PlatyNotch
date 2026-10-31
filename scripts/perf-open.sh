#!/usr/bin/env bash
# CPU with the panel OPEN and the weather sky moving (Island spec 5; phase A review I6).
#
# For each sky (default: clear rain snow), with a fake track playing: builds the Go core and
# serves it from a throwaway PLATYNOTCH_HOME, starts the release app with
#   --perf-run PLATYNOTCH_FAKE_NOWPLAYING=1 PLATYNOTCH_PERF_SKY=<sky> PLATYNOTCH_PERF_OPEN_SECONDS=<n>
# (the weather is pinned to that condition, no network; Home opens 1 s after launch and
# closes itself after <n> s), and samples `top -s 1` for the app and WindowServer:
#   open   the mean over PN_OPEN_SAMPLES seconds after a warm-up, panel open (limit 5 %)
#   closed each second after the close; the app must be under 1 % by the 2nd second, and
#          the mean of seconds 3–10 is reported.
# The panel is on screen at the notch while this runs. Needs a real Mac session; not CI.
#
# Environment: PN_SKIES ("clear rain snow"), PN_OPEN_LIMIT (5.0), PN_CLOSED_LIMIT (1.0),
# PN_WARMUP (8), PN_OPEN_SAMPLES (30), PN_SCRATCH (a --scratch-path for swift build),
# PN_APP_BIN (use this executable instead of building). WindowServer is reported against its
# own mean over 10 s before the run (other apps' drawing counts there too).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIES="${PN_SKIES:-clear rain snow}"
OPEN_LIMIT="${PN_OPEN_LIMIT:-5.0}"
CLOSED_LIMIT="${PN_CLOSED_LIMIT:-1.0}"
WARMUP="${PN_WARMUP:-8}"
OPEN_SAMPLES="${PN_OPEN_SAMPLES:-30}"
AFTER=10

log() { printf '%s\n' "$*" >&2; }

WORK="$(mktemp -d /tmp/pnopen.XXXX)"
SERVE_PID=""; APP_PID=""
# cleanup runs only through `trap cleanup EXIT`, which shellcheck does not follow.
# shellcheck disable=SC2317
cleanup() {
  if [[ -n "$APP_PID" ]]; then kill "$APP_PID" 2>/dev/null || true; fi
  if [[ -n "$SERVE_PID" ]]; then kill "$SERVE_PID" 2>/dev/null || true; fi
  sleep 0.5
  rm -rf "$WORK"
}
trap cleanup EXIT

(cd "$ROOT/core" && go build -o "$WORK/notch" ./cmd/notch)
if [[ -n "${PN_APP_BIN:-}" ]]; then
  APP_BIN="$PN_APP_BIN"
else
  SCRATCH=()
  [[ -n "${PN_SCRATCH:-}" ]] && SCRATCH=(--scratch-path "$PN_SCRATCH")
  log "swift build (release)"
  (cd "$ROOT/apps/mac" && swift build -c release ${SCRATCH[@]+"${SCRATCH[@]}"} --product PlatyNotch >&2)
  APP_BIN="$(cd "$ROOT/apps/mac" && swift build -c release ${SCRATCH[@]+"${SCRATCH[@]}"} --show-bin-path)/PlatyNotch"
fi
WS_PID="$(pgrep -x WindowServer | head -1)"
# WindowServer before any test app: what the rest of the Mac costs it.
WS_BASE="$(top -l 11 -s 1 -pid "$WS_PID" -stats pid,cpu | awk -v p="$WS_PID" '$1 == p { n++; if (n > 1) { s += $2; c++ } } END { printf "%.2f", c ? s / c : 0 }')"
printf 'WindowServer before the run: %s%%\n' "$WS_BASE"

status=0
for SKY in $SKIES; do
  HOME_DIR="$WORK/h-$SKY"; SOCKET="$WORK/$SKY.sock"
  mkdir -p "$HOME_DIR"
  export PLATYNOTCH_HOME="$HOME_DIR" PLATYNOTCH_SOCKET="$SOCKET" PLATYNOTCH_USER_HOME="$HOME_DIR/user"
  "$WORK/notch" serve >"$WORK/serve-$SKY.log" 2>&1 &
  SERVE_PID=$!
  for _ in $(seq 100); do [[ -S "$SOCKET" ]] && break; sleep 0.1; done
  OPEN_FOR=$(( WARMUP + OPEN_SAMPLES + 2 ))
  PLATYNOTCH_FAKE_NOWPLAYING=1 PLATYNOTCH_EXTERNAL_CORE=1 PLATYNOTCH_PERF_SKY="$SKY" \
    PLATYNOTCH_PERF_OPEN_SECONDS="$OPEN_FOR" "$APP_BIN" --perf-run \
    -widgets.layout "" -appearance.minimal NO -appearance.showOnAllDisplays NO -appearance.liveSide right \
    >"$WORK/app-$SKY.log" 2>&1 &
  APP_PID=$!
  START=$(date +%s)
  sleep "$WARMUP"
  # Panel open: OPEN_SAMPLES seconds (+1 dropped).
  OPEN_VALUES="$(top -l $(( OPEN_SAMPLES + 1 )) -s 1 -pid "$APP_PID" -pid "$WS_PID" -stats pid,cpu \
    | awk -v app="$APP_PID" -v ws="$WS_PID" '$1 == app || $1 == ws { print $1, $2 }')"
  # Until the close (launch + 1 + OPEN_FOR), then AFTER seconds closed.
  CLOSE_AT=$(( START + 1 + OPEN_FOR ))
  while [[ $(date +%s) -lt $CLOSE_AT ]]; do sleep 0.2; done
  CLOSED_VALUES="$(top -l $(( AFTER + 1 )) -s 1 -pid "$APP_PID" -stats pid,cpu \
    | awk -v app="$APP_PID" '$1 == app { print $2 }' | tail -n +2)"
  REOPENED="$(grep -c "PERF-SKY reopened" "$WORK/app-$SKY.log" || true)"
  [[ "$REOPENED" != 0 ]] && log "note: $SKY: the panel was closed from outside and reopened $REOPENED time(s)"
  grep -q "PERF-SKY open" "$WORK/app-$SKY.log" || log "warning: the app did not log PERF-SKY open"
  grep -q "PERF-SKY closed" "$WORK/app-$SKY.log" || log "warning: the app did not log PERF-SKY closed"
  APP_OPEN="$(printf '%s\n' "$OPEN_VALUES" | awk -v p="$APP_PID" '$1 == p { n++; if (n > 1) { s += $2; c++ } } END { printf "%.2f", c ? s / c : 0 }')"
  WS_OPEN="$(printf '%s\n' "$OPEN_VALUES" | awk -v p="$WS_PID" '$1 == p { n++; if (n > 1) { s += $2; c++ } } END { printf "%.2f", c ? s / c : 0 }')"
  OPEN_LIST="$(printf '%s\n' "$OPEN_VALUES" | awk -v p="$APP_PID" '$1 == p { n++; if (n > 1) printf "%s ", $2 }')"
  APP_MEDIAN="$(printf '%s\n' "$OPEN_LIST" | tr ' ' '\n' | grep -v '^$' | sort -n | awk '{ v[NR] = $1 } END { printf "%.2f", NR ? v[int((NR + 1) / 2)] : 0 }')"
  [[ -n "${PN_VERBOSE:-}" ]] && printf '  %s open per second: %s\n' "$SKY" "$OPEN_LIST"
  SECONDS_LIST="$(printf '%s\n' "$CLOSED_VALUES" | tr '\n' ' ')"
  SECOND2="$(printf '%s\n' "$CLOSED_VALUES" | sed -n 2p)"
  REST="$(printf '%s\n' "$CLOSED_VALUES" | sed -n '3,$p' | awk '{ s += $1; c++ } END { printf "%.2f", c ? s / c : 0 }')"
  verdict=PASS
  awk -v a="$APP_OPEN" -v l="$OPEN_LIMIT" 'BEGIN { exit !(a > l) }' && verdict=FAIL
  awk -v a="${SECOND2:-99}" -v l="$CLOSED_LIMIT" 'BEGIN { exit !(a > l) }' && verdict=FAIL
  [[ $verdict == FAIL ]] && status=1
  printf '%s: open app %s%% (median %s%%; WindowServer %s%%) | closed per second: %s| 2nd s %s%%, s3-10 mean %s%% | %s\n' \
    "$SKY" "$APP_OPEN" "$APP_MEDIAN" "$WS_OPEN" "$SECONDS_LIST" "${SECOND2:-?}" "$REST" "$verdict"
  kill "$APP_PID" 2>/dev/null || true; APP_PID=""
  kill "$SERVE_PID" 2>/dev/null || true; SERVE_PID=""
  sleep 1
done
exit $status
