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
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/qwen/hooks.go; activitystate/activitystate.go (StandardDeriveActivityState, used for qwen in activitydispatch).
//
// Modified for PlatyNotch: installs into the user-level ~/.qwen/settings.json through hookjson; commands are `notch hook qwen <event>`; returns protocol.State.

// Package qwen is the Qwen Code adapter (state tracking only, no approvals).
package qwen

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/platynotch/platynotch/core/agents"
	"github.com/platynotch/platynotch/core/hookjson"
	"github.com/platynotch/platynotch/core/paths"
	"github.com/platynotch/platynotch/core/protocol"
)

const agentID = "qwen"

func init() { agents.Register(Adapter{}) }

// Adapter implements agents.Adapter for Qwen Code.
type Adapter struct{}

func (Adapter) ID() string   { return agentID }
func (Adapter) Name() string { return "Qwen Code" }

func (Adapter) Detect() bool {
	if st, err := os.Stat(filepath.Join(paths.UserHome(), ".qwen")); err == nil && st.IsDir() {
		return true
	}
	_, err := exec.LookPath("qwen")
	return err == nil
}

func (Adapter) ConfigPath() string {
	return filepath.Join(paths.UserHome(), ".qwen", "settings.json")
}

func (a Adapter) spec(hookBin string) hookjson.Spec {
	s := hookjson.Spec{Path: a.ConfigPath(), Format: hookjson.FormatClaude}
	for _, e := range managedEvents {
		ent := hookjson.Entry{Event: e.event, Command: hookjson.Command(hookBin, agentID, e.kebab), Matcher: e.matcher, TimeoutSec: e.timeout}
		s.Entries = append(s.Entries, ent)
	}
	return s
}

func (a Adapter) InstallHooks(hookBin string) (bool, error) {
	return hookjson.Install(a.spec(hookBin))
}

func (a Adapter) UninstallHooks() (bool, error) { return hookjson.Uninstall(a.spec("notch")) }

func (a Adapter) HooksInstalled() (bool, error) { return hookjson.Installed(a.spec("notch")) }

func (Adapter) DeriveState(event string, payload []byte) (protocol.State, bool) {
	return deriveState(event, payload)
}

func (Adapter) ParseCommon(_ string, payload []byte) agents.Common {
	var p struct {
		SessionID        string          `json:"session_id"`
		CWD              string          `json:"cwd"`
		ToolName         string          `json:"tool_name"`
		ToolUseID        string          `json:"tool_use_id"`
		Prompt           string          `json:"prompt"`
		Message          string          `json:"message"`
		NotificationType string          `json:"notification_type"`
		TranscriptPath   string          `json:"transcript_path"`
		ToolInput        json.RawMessage `json:"tool_input"`
	}
	_ = json.Unmarshal(payload, &p)
	return agents.Common{
		SessionID: p.SessionID, CWD: p.CWD, Tool: p.ToolName, ToolUseID: p.ToolUseID,
		Prompt: p.Prompt, Message: p.Message, NotificationType: p.NotificationType,
		TranscriptPath: p.TranscriptPath, ToolInput: p.ToolInput,
	}
}

// Approvals: Qwen Code has no verified approve-from-the-notch path.
func (Adapter) Approvals() agents.ApprovalSupport { return agents.ApprovalsNone }

// IsPermissionEvent reports the permission event for state tracking only.
func (Adapter) IsPermissionEvent(event string) bool { return event == permissionEvent }

// FormatDecision prints nothing: decisions are not supported for Qwen Code.
func (Adapter) FormatDecision(string, protocol.HookDecision) []byte { return nil }

const permissionEvent = "permission-request"

// hookTimeout is in milliseconds: Qwen Code (a gemini-cli fork) measures
// hook timeouts in ms (AO: qwenHookTimeout 30000).
const hookTimeout = 30000

// sessionStartMatcher is the Qwen-documented startup and resume source matcher.
var sessionStartMatcher = "startup|resume"

// managedEvents (AO qwenManagedHooks): native event and kebab-case sub-command.
var managedEvents = []struct {
	event, kebab string
	matcher      *string
	timeout      int
}{
	{"SessionStart", "session-start", &sessionStartMatcher, hookTimeout},
	{"UserPromptSubmit", "user-prompt-submit", nil, hookTimeout},
	{"PermissionRequest", permissionEvent, nil, hookTimeout},
	{"Stop", "stop", nil, hookTimeout},
}
