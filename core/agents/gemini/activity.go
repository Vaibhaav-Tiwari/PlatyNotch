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
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/gemini/hooks.go (DeriveActivityState).
//
// Modified for PlatyNotch: returns protocol.State instead of AO's domain.ActivityState.

package gemini

import (
	"encoding/json"

	"github.com/platynotch/platynotch/core/protocol"
)

// deriveState maps a Gemini hook sub-command (and payload) onto a
// protocol.State; false means no activity signal.
func deriveState(event string, payload []byte) (protocol.State, bool) {
	switch event {
	case "session-start", "user-prompt-submit", "after-tool":
		return protocol.StateActive, true
	case "stop":
		return protocol.StateIdle, true
	case "notification":
		var p struct {
			Type string `json:"notification_type"`
		}
		if json.Unmarshal(payload, &p) == nil && p.Type == "ToolPermission" {
			return protocol.StateWaitingInput, true
		}
	}
	return "", false
}
