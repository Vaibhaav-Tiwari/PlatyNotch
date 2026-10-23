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
// Ported from agent-orchestrator (https://github.com/OrchestratorInc/agent-orchestrator,
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/claudecode/hooks.go.
//
// Modified for PlatyNotch: installs into the user-level ~/.claude/settings.json
// through hookjson instead of a workspace-local settings.local.json; commands
// are `notch hook claude-code <event>`; PermissionRequest gets a 120s timeout;
// SubagentStart/SubagentStop are installed; adds approve-from-the-notch output.

// Package claudecode is the Claude Code adapter, the one agent with verified
// approve-from-the-notch.
package claudecode

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/hookjson"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

const (
	agentID           = "claude-code"
	permissionEvent   = "permission-request"
	permissionTimeout = 120
	defaultDenyMsg    = "Denied from PlatyNotch."
)

func init() { agents.Register(Adapter{}) }

// sessionStartMatcher is referenced by pointer so SessionStart serializes
// with Claude's documented source matcher. "startup" alone misses --resume
// relaunches (and /clear, compact, fork).
var sessionStartMatcher = "startup|resume|clear|compact|fork"

// managedEvents: native event name and its kebab-case hook sub-command.
var managedEvents = []struct{ event, kebab string }{
	{"SessionStart", "session-start"},
	{"UserPromptSubmit", "user-prompt-submit"},
	{"PreToolUse", "pre-tool-use"},
	{"PostToolUse", "post-tool-use"},
	{"PostToolUseFailure", "post-tool-use-failure"},
	{"PermissionRequest", permissionEvent},
	{"Stop", "stop"},
	// StopFailure fires instead of Stop when an API error ends the turn.
	{"StopFailure", "stop-failure"},
	{"Notification", "notification"},
	{"SubagentStart", "subagent-start"},
	{"SubagentStop", "subagent-stop"},
	{"SessionEnd", "session-end"},
}

// Adapter implements agents.Adapter for Claude Code.
type Adapter struct{}

func (Adapter) ID() string   { return agentID }
func (Adapter) Name() string { return "Claude Code" }

func (Adapter) Detect() bool {
	if st, err := os.Stat(filepath.Join(paths.UserHome(), ".claude")); err == nil && st.IsDir() {
		return true
	}
	_, err := exec.LookPath("claude")
	return err == nil
}

func (Adapter) ConfigPath() string {
	return filepath.Join(paths.UserHome(), ".claude", "settings.json")
}

func (a Adapter) spec(hookBin string) hookjson.Spec {
	s := hookjson.Spec{Path: a.ConfigPath(), Format: hookjson.FormatClaude}
	for _, e := range managedEvents {
		ent := hookjson.Entry{Event: e.event, Command: hookjson.Command(hookBin, agentID, e.kebab)}
		if e.event == "SessionStart" {
			ent.Matcher = &sessionStartMatcher
		}
		if e.kebab == permissionEvent {
			ent.TimeoutSec = permissionTimeout
		}
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

func (Adapter) Approvals() agents.ApprovalSupport { return agents.ApprovalsVerified }

func (Adapter) IsPermissionEvent(event string) bool { return event == permissionEvent }

type decisionOut struct {
	HookSpecificOutput struct {
		HookEventName string `json:"hookEventName"`
		Decision      struct {
			Behavior string `json:"behavior"`
			Message  string `json:"message,omitempty"`
		} `json:"decision"`
	} `json:"hookSpecificOutput"`
}

// FormatDecision renders the PermissionRequest reply. Shape verified against
// https://code.claude.com/docs/en/hooks ("PermissionRequest decision control":
// hookSpecificOutput.decision.behavior allow|deny, message for deny only).
func (a Adapter) FormatDecision(event string, d protocol.HookDecision) []byte {
	if !a.IsPermissionEvent(event) {
		return nil
	}
	var o decisionOut
	o.HookSpecificOutput.HookEventName = "PermissionRequest"
	switch d.Behavior {
	case protocol.BehaviorAllow:
		o.HookSpecificOutput.Decision.Behavior = "allow"
	case protocol.BehaviorDeny:
		o.HookSpecificOutput.Decision.Behavior = "deny"
		o.HookSpecificOutput.Decision.Message = d.Message
		if d.Message == "" {
			o.HookSpecificOutput.Decision.Message = defaultDenyMsg
		}
	default:
		return nil
	}
	b, _ := json.Marshal(o)
	return b
}
