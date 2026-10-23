#!/usr/bin/env bash
# Drives a real `notch serve` with fake Claude Code hook events so the notch
# panel can be checked by hand (see scripts/verify-panel.md).
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: scripts/fake-events.sh [--auto] [--help]

Builds the core to /tmp/pn-notch, serves it from a throwaway PLATYNOTCH_HOME with
a short socket path, prints the command that starts the app against it, then sends
Claude Code hook events: an active session, a permission request, a second session
with its own permission request, and a stop for both.

  --auto    no prompts; short pauses between steps (PN_FAKE_HOLD=<s> keeps the core
            up that long at the end, default 5)
  --help    show this help

Environment: a preset PLATYNOTCH_HOME / PLATYNOTCH_SOCKET is used as is (start the
app first, then this script). KEEP_BIN=1 keeps /tmp/pn-notch after exit.
Nothing touches ~/Library/Application Support/PlatyNotch or your ~/.claude.
USAGE
}

AUTO=0
for arg in "$@"; do
  case "$arg" in
    --auto) AUTO=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=/tmp/pn-notch

# json_str <s>: <s> as a JSON string literal (quotes, backslashes, control chars escaped).
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

CREATED=()
SERVE_PID=""
HOOK_PIDS=()

# kill_tree <pid>: the process and all its descendants.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$child"; done
  kill "$1" 2>/dev/null || true
}

cleanup() {
  local p d
  for p in "${HOOK_PIDS[@]:-}"; do [[ -n "$p" ]] && kill_tree "$p"; done
  if [[ -n "$SERVE_PID" ]]; then kill_tree "$SERVE_PID"; wait "$SERVE_PID" 2>/dev/null || true; fi
  for d in "${CREATED[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done
  [[ "${KEEP_BIN:-0}" == 1 ]] || rm -f "$BIN"
  # Anything else still in our process group (when we lead it, i.e. run from a shell).
  if [[ "$(ps -o pgid= -p $$ | tr -d ' ')" == "$$" ]]; then
    trap - TERM
    kill -- -$$ 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> building core: $BIN"
(cd "$ROOT/core" && go build -o "$BIN" ./cmd/notch)

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

echo "==> notch serve (home $PLATYNOTCH_HOME)"
"$BIN" serve >"$PLATYNOTCH_HOME/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 100); do
  [[ -S "$PLATYNOTCH_SOCKET" ]] && break
  kill -0 "$SERVE_PID" 2>/dev/null || { echo "notch serve exited:"; cat "$PLATYNOTCH_HOME/serve.log"; exit 1; }
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

CWD_JSON="$(json_str "$PWD")"

# hook <event> <json>: one Claude Code hook event, as Claude would run it.
hook() {
  printf '%s' "$2" | "$BIN" hook claude-code "$1"
}

# permission <session> <command>: runs in the background; prints the decision when answered.
permission() {
  local sid="$1" cmd="$2" payload
  payload="{\"session_id\":$(json_str "$sid"),\"cwd\":$CWD_JSON,\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(json_str "$cmd"),\"description\":\"fake-events\"},\"tool_use_id\":$(json_str "toolu_$sid")}"
  (
    out="$(printf '%s' "$payload" | "$BIN" hook claude-code permission-request)"
    echo
    echo "    [$sid] decision: ${out:-<none: expired, or no UI connected>}"
  ) &
  HOOK_PIDS+=($!)
}

start_session() {
  local sid prompt
  sid="$(json_str "$1")"; prompt="$(json_str "$2")"
  hook session-start "{\"session_id\":$sid,\"cwd\":$CWD_JSON,\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  hook user-prompt-submit "{\"session_id\":$sid,\"cwd\":$CWD_JSON,\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":$prompt}"
  hook pre-tool-use "{\"session_id\":$sid,\"cwd\":$CWD_JSON,\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"README.md\"}}"
}

stop_session() {
  hook stop "{\"session_id\":$(json_str "$1"),\"hook_event_name\":\"Stop\"}"
}

step "1/5 active session fake-1 (agent dot goes active; Minimal mode shows the pill)" 2
start_session fake-1 'Refactor the "notch" panel'

step "2/5 permission request from fake-1 (panel peeks with the approval and stays)" 2
permission fake-1 'npm test -- --grep "panel \"peek\""'

step "3/5 second permission request from fake-2 (two approvals, oldest first)" 2
start_session fake-2 "Fix the flaky test"
permission fake-2 "git status"

step "4/5 stop both sessions (sessions idle; approvals stay until answered or expired)" 4
stop_session fake-1
stop_session fake-2

if [[ $AUTO == 1 ]]; then
  echo
  echo "==> 5/5 done; core keeps running ${PN_FAKE_HOLD:-5}s"
  sleep "${PN_FAKE_HOLD:-5}"
else
  echo
  echo "==> 5/5 done. The core keeps running; Ctrl-C to stop it and clean up."
  wait "$SERVE_PID"
fi
