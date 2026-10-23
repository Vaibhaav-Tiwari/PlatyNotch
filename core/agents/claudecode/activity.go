// Copyright 2026 Untrivial
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from agent-orchestrator (https://github.com/aoagents/agent-orchestrator,
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/claudecode/activity.go.
//
// Modified for PlatyNotch: returns protocol.State instead of AO's
// domain.ActivityState; comments referencing AO internals kept as rationale.

package claudecode

import (
	"encoding/json"

	"github.com/platynotch/platynotch/core/protocol"
)

// deriveState maps a Claude Code hook event (and its native stdin
// payload) onto a protocol.State. The bool is false when the event carries
// no activity signal — e.g. SessionStart (metadata only, v1), a Notification
// type we don't track, or a SessionEnd reason that doesn't actually end the AO
// session — in which case the caller reports nothing.
//
// event is the PlatyNotch hook sub-command name installed in managedEvents
// ("user-prompt-submit", "stop", "notification", "session-end", ...), NOT the
// native Claude event name. Keeping this beside hooks.go means the events AO
// installs and what they mean live in one place.
func deriveState(event string, payload []byte) (protocol.State, bool) {
	switch event {
	case "user-prompt-submit":
		return protocol.StateActive, true
	case "pre-tool-use", "post-tool-use", "post-tool-use-failure":
		// The agent is executing tools — active. These signals carry
		// tool_name/tool_use_id on the wire, and lifecycle applies them under
		// a precedence rule: they never demote a sticky state, EXCEPT the
		// post of the exact tool whose permission dialog blocked the session
		// (approval means the tool ran — the earliest observable "the
		// decision was resolved" signal, since answering a dialog fires no
		// hook of its own). Without the rule, parallel-subagent traffic would
		// clear a live blocked — the failure that reverted the naive mapping
		// in PR #5's review.
		return protocol.StateActive, true
	case "permission-request":
		// Fires when a permission dialog appears — earlier and richer than
		// Notification(permission_prompt): the payload names the blocking
		// tool, which lifecycle snapshots for the correlated clear above.
		return protocol.StateBlocked, true
	case "stop":
		// End of a turn: the agent is idle but alive (not exited). A following
		// Notification(idle_prompt) also maps to idle, so a finished turn reads
		// Idle until the next prompt; only a real permission request flips it
		// to waiting_input. An Esc interrupt fires no Stop; the turn-failure
		// observer reads it from the transcript (turn_interrupts.go).
		return protocol.StateIdle, true
	case "stop-failure":
		// StopFailure fires instead of Stop when an API error ended the turn
		// (rate or usage limit, unknown model, expired login, server error).
		// The agent is back at its prompt, so the turn ended like a Stop.
		return protocol.StateIdle, true
	case "notification":
		return notificationState(payload)
	case "session-end":
		return sessionEndState(payload)
	default:
		return "", false
	}
}

// notificationState splits the notification types that mean "the agent is
// paused on the user" by what unblocks them:
//   - idle_prompt: the agent finished its turn and sits idle at the prompt
//     awaiting the next instruction — that is Idle, not a blocking request,
//     so a stop/interrupt reads Idle rather than "Input Needed".
//   - agent_needs_input: a request for user input that carries no tool
//     identity — waiting_input (automated nudges stay suppressed via
//     NeedsInput, user sends deliver). It must NOT map to blocked: without a
//     tool to correlate, the block could only lift at a turn boundary,
//     rejecting user sends long after the question was answered.
//   - permission_prompt: a pending permission decision (blocked — a stray
//     Enter could answer the dialog). It duplicates the earlier
//     permission-request hook, whose payload names the blocking tool for the
//     correlated clear.
//   - agent_completed (fired by `claude agents` background sessions,
//     CLI 2.1.198+): the turn finished — Stop semantics, idle but alive.
//
// Other types (auth_success, elicitation_*) carry no activity meaning, as
// does a malformed payload.
func notificationState(payload []byte) (protocol.State, bool) {
	var p struct {
		NotificationType string `json:"notification_type"`
	}
	_ = json.Unmarshal(payload, &p)
	switch p.NotificationType {
	case "idle_prompt", "agent_completed":
		return protocol.StateIdle, true
	case "agent_needs_input":
		return protocol.StateWaitingInput, true
	case "permission_prompt":
		return protocol.StateBlocked, true
	default:
		return "", false
	}
}

// sessionEndState reports exited for reasons that actually end the session.
// clear/resume keep the same AO session alive (a new native session continues
// in the worktree), so they report nothing. Any other reason — logout,
// prompt_input_exit, bypass_permissions_disabled, other, or an absent/unknown
// reason on a SessionEnd that did fire — is treated as a real exit. SessionEnd
// is not guaranteed on crash/SIGKILL, so the reaper remains the backstop; both
// paths guard on IsTerminated, so whichever lands first wins.
func sessionEndState(payload []byte) (protocol.State, bool) {
	var p struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(payload, &p)
	switch p.Reason {
	case "clear", "resume":
		return "", false
	default:
		return protocol.StateExited, true
	}
}
