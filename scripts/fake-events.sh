#!/usr/bin/env bash
# Drives a real `notch serve` with fake Claude Code hook events so the notch
# panel can be checked by hand (see scripts/verify-panel.md).
#
#   scripts/fake-events.sh          # interactive: press Enter between steps
#   scripts/fake-events.sh --auto   # no prompts, short pauses between steps
#
# It builds the core to /tmp/pn-notch, serves it from a throwaway
# PLATYNOTCH_HOME with a short socket path, and prints the command that starts
# the app against it. Nothing touches ~/Library/Application Support/PlatyNotch.
set -euo pipefail

AUTO=0
[[ "${1:-}" == "--auto" ]] && AUTO=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/tmp/pn-notch

echo "==> building core: $BIN"
(cd "$ROOT/core" && go build -o "$BIN" ./cmd/notch)

# A preset PLATYNOTCH_HOME / PLATYNOTCH_SOCKET is honoured (start the app first,
# then this script); otherwise throwaway ones are created and removed on exit.
CREATED=()
if [[ -z "${PLATYNOTCH_HOME:-}" ]]; then
  PLATYNOTCH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/pn-home.XXXXXX")"; CREATED+=("$PLATYNOTCH_HOME")
fi
if [[ -z "${PLATYNOTCH_SOCKET:-}" ]]; then
  SOCK_DIR="$(mktemp -d /tmp/pn.XXXX)"; CREATED+=("$SOCK_DIR")   # macOS caps socket paths at 104 bytes
  PLATYNOTCH_SOCKET="$SOCK_DIR/n.sock"
fi
export PLATYNOTCH_HOME PLATYNOTCH_SOCKET
export PLATYNOTCH_USER_HOME="$PLATYNOTCH_HOME/user"   # hooks never touch your real ~/.claude
mkdir -p "$PLATYNOTCH_USER_HOME"
HOME_DIR="$PLATYNOTCH_HOME"

SERVE_PID=""
HOOK_PIDS=()
cleanup() {
  for p in "${HOOK_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  if [[ -n "$SERVE_PID" ]]; then kill "$SERVE_PID" 2>/dev/null || true; wait "$SERVE_PID" 2>/dev/null || true; fi
  for d in "${CREATED[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> notch serve (home $HOME_DIR)"
"$BIN" serve >"$HOME_DIR/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 100); do
  [[ -S "$PLATYNOTCH_SOCKET" ]] && break
  kill -0 "$SERVE_PID" 2>/dev/null || { echo "notch serve exited:"; cat "$HOME_DIR/serve.log"; exit 1; }
  sleep 0.1
done
[[ -S "$PLATYNOTCH_SOCKET" ]] || { echo "notch serve never listened"; exit 1; }

cat <<MSG

Start the app against this core in another terminal:

  cd "$ROOT/apps/mac" && PLATYNOTCH_EXTERNAL_CORE=1 PLATYNOTCH_HOME="$PLATYNOTCH_HOME" PLATYNOTCH_SOCKET="$PLATYNOTCH_SOCKET" swift run PlatyNotch

Approvals only appear while the app is connected (with no UI the hook does not wait).
MSG

step() {
  echo
  echo "==> $1"
  if [[ $AUTO == 1 ]]; then sleep "${2:-1}"; else read -r -p "    press Enter to continue " _; fi
}

# hook <event> <json>: one Claude Code hook event, as Claude would run it.
hook() {
  printf '%s' "$2" | "$BIN" hook claude-code "$1"
}

# permission <session> <command>: runs in the background; prints the decision when answered.
permission() {
  local sid="$1" cmd="$2"
  (
    out="$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"%s","description":"fake-events"},"tool_use_id":"toolu_%s"}' \
      "$sid" "$PWD" "$cmd" "$sid" | "$BIN" hook claude-code permission-request)"
    echo
    echo "    [$sid] decision: ${out:-<none: expired, or no UI connected>}"
  ) &
  HOOK_PIDS+=($!)
}

start_session() {
  local sid="$1" prompt="$2"
  hook session-start "{\"session_id\":\"$sid\",\"cwd\":\"$PWD\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  hook user-prompt-submit "{\"session_id\":\"$sid\",\"cwd\":\"$PWD\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"$prompt\"}"
  hook pre-tool-use "{\"session_id\":\"$sid\",\"cwd\":\"$PWD\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"README.md\"}}"
}

step "1/5 active session fake-1 (agent dot goes active; Minimal mode shows the pill)" 2
start_session fake-1 "Refactor the notch panel"

step "2/5 permission request from fake-1 (panel peeks with the approval and stays)" 2
permission fake-1 "npm test"

step "3/5 second permission request from fake-2 (two approvals, oldest first)" 2
start_session fake-2 "Fix the flaky test"
permission fake-2 "git status"

step "4/5 stop both sessions (sessions idle; approvals stay until answered or expired)" 4
hook stop '{"session_id":"fake-1","hook_event_name":"Stop"}'
hook stop '{"session_id":"fake-2","hook_event_name":"Stop"}'

if [[ $AUTO == 1 ]]; then
  echo
  echo "==> 5/5 done; core keeps running ${PN_FAKE_HOLD:-5}s"
  sleep "${PN_FAKE_HOLD:-5}"
else
  echo
  echo "==> 5/5 done. The core keeps running; Ctrl-C to stop it and clean up."
  wait "$SERVE_PID"
fi
