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
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/codex/activity.go.
//
// Modified for PlatyNotch: returns protocol.State instead of AO's domain.ActivityState.

package codex

import "github.com/platynotch/platynotch/core/protocol"

// deriveState maps a Codex hook sub-command onto a protocol.State; false
// means no activity signal. Codex has no SessionEnd/Notification hook, so
// exit is left to the process watcher.
func deriveState(event string, _ []byte) (protocol.State, bool) {
	switch event {
	case "user-prompt-submit":
		return protocol.StateActive, true
	case "permission-request":
		// waiting_input, not blocked: Codex's only PostToolUse hook tracks
		// successful subagent spawns, not approval resolution, so a blocked
		// state could stay stuck until the turn ends.
		return protocol.StateWaitingInput, true
	case "stop":
		return protocol.StateIdle, true
	default:
		return "", false
	}
}
