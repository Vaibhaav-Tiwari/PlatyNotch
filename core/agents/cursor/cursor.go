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
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/cursor/hooks.go, activity.go; internal/cli/hooks.go (cursor permission hook).
//
// Modified for PlatyNotch: installs into the user-level ~/.cursor/hooks.json through hookjson; commands are `notch hook cursor <event>`; failClosed is NOT set on any entry (a broken hook must never block the agent); adds approve-from-the-notch output (experimental).

// Package cursor is the Cursor adapter. Approve-from-the-notch is
// experimental until checked against Cursor's hooks documentation.
package cursor

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/hookjson"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

const (
	agentID        = "cursor"
	defaultDenyMsg = "Denied from PlatyNotch."
	// permissionTimeout (seconds) gives the user time to answer in the notch.
	permissionTimeout = 120
)

func init() { agents.Register(Adapter{}) }

// managedEvents: Cursor's native camelCase event and its kebab-case hook
// sub-command (AO cursorManagedHooks, minus failClosed).
var managedEvents = []struct {
	event, kebab string
	timeout      int
}{
	{"sessionStart", "session-start", 0},
	{"beforeSubmitPrompt", "user-prompt-submit", 0},
	{"stop", "stop", 0},
	{"beforeShellExecution", "before-shell-execution", permissionTimeout},
	{"beforeMCPExecution", "before-mcp-execution", permissionTimeout},
	{"afterShellExecution", "after-shell-execution", 0},
	{"afterMCPExecution", "after-mcp-execution", 0},
	{"postToolUse", "post-tool-use", 0},
	{"postToolUseFailure", "post-tool-use-failure", 0},
}

// Adapter implements agents.Adapter for Cursor.
type Adapter struct{}

func (Adapter) ID() string   { return agentID }
func (Adapter) Name() string { return "Cursor" }

func (Adapter) Detect() bool {
	if st, err := os.Stat(filepath.Join(paths.UserHome(), ".cursor")); err == nil && st.IsDir() {
		return true
	}
	_, err := exec.LookPath("cursor-agent")
	return err == nil
}

func (Adapter) ConfigPath() string {
	return filepath.Join(paths.UserHome(), ".cursor", "hooks.json")
}

func (a Adapter) spec(hookBin string) hookjson.Spec {
	s := hookjson.Spec{Path: a.ConfigPath(), Format: hookjson.FormatCursor}
	for _, e := range managedEvents {
		s.Entries = append(s.Entries, hookjson.Entry{Event: e.event, Command: hookjson.Command(hookBin, agentID, e.kebab), TimeoutSec: e.timeout})
	}
	return s
}

func (a Adapter) InstallHooks(hookBin string) (bool, error) {
	return hookjson.Install(a.spec(hookBin))
}

func (a Adapter) UninstallHooks() (bool, error) { return hookjson.Uninstall(a.spec("notch")) }

func (a Adapter) HooksInstalled() (bool, error) { return hookjson.Installed(a.spec("notch")) }

// DeriveState maps a Cursor hook sub-command onto a protocol.State. The
// before-execution hooks carry no fixed mapping (AO evaluates permission
// separately), so they report nothing here.
func (Adapter) DeriveState(event string, _ []byte) (protocol.State, bool) {
	switch event {
	case "session-start", "user-prompt-submit",
		"after-shell-execution", "after-mcp-execution", "post-tool-use", "post-tool-use-failure":
		return protocol.StateActive, true
	case "stop":
		return protocol.StateIdle, true
	default:
		return "", false
	}
}

// ParseCommon normalizes Cursor payloads: conversation_id is the session,
// the first workspace root is the cwd, and shell hooks carry a bare command.
func (Adapter) ParseCommon(event string, payload []byte) agents.Common {
	var p struct {
		ConversationID string          `json:"conversation_id"`
		SessionID      string          `json:"session_id"`
		CWD            string          `json:"cwd"`
		WorkspaceRoots []string        `json:"workspace_roots"`
		ToolName       string          `json:"tool_name"`
		ToolUseID      string          `json:"tool_use_id"`
		ToolInput      json.RawMessage `json:"tool_input"`
		Command        string          `json:"command"`
		Prompt         string          `json:"prompt"`
		TranscriptPath string          `json:"transcript_path"`
	}
	_ = json.Unmarshal(payload, &p)
	c := agents.Common{
		SessionID: p.ConversationID, CWD: p.CWD, Tool: p.ToolName, ToolUseID: p.ToolUseID,
		Prompt: p.Prompt, TranscriptPath: p.TranscriptPath, ToolInput: p.ToolInput,
	}
	if c.SessionID == "" {
		c.SessionID = p.SessionID
	}
	if c.CWD == "" && len(p.WorkspaceRoots) > 0 {
		c.CWD = p.WorkspaceRoots[0]
	}
	switch event {
	case "before-shell-execution", "after-shell-execution":
		c.Tool = "Shell" // whatever tool_name the payload claims
		// The top-level command is what Cursor runs; prefer it.
		if p.Command != "" {
			c.ToolInput, _ = json.Marshal(map[string]string{"command": p.Command})
		}
	}
	return c
}

func (Adapter) Approvals() agents.ApprovalSupport { return agents.ApprovalsExperimental }

// PolicySummary: before-shell-execution is KindCommand from the top-level
// "command" (see agents.ShellSummary: a differing tool_input.command or an
// unexpected tool_input key makes it KindOther); before-mcp-execution and
// every other event are always KindOther, whatever the tool is named.
func (Adapter) PolicySummary(event string, payload []byte) (string, agents.SummaryKind) {
	var p struct {
		Command   string          `json:"command"`
		ToolInput json.RawMessage `json:"tool_input"`
	}
	_ = json.Unmarshal(payload, &p)
	if event == "before-shell-execution" {
		return agents.ShellSummary(p.Command, p.ToolInput)
	}
	s, _ := agents.SummarizeFull("", p.ToolInput)
	return s, policy.KindOther
}

func (Adapter) IsPermissionEvent(event string) bool {
	return event == "before-shell-execution" || event == "before-mcp-execution"
}

type decisionOut struct {
	Permission   string `json:"permission"`
	UserMessage  string `json:"user_message,omitempty"`
	AgentMessage string `json:"agent_message,omitempty"`
}

// FormatDecision renders the before-execution reply:
// {"permission":"allow"} or {"permission":"deny","user_message","agent_message"}.
func (a Adapter) FormatDecision(event string, d protocol.HookDecision) []byte {
	if !a.IsPermissionEvent(event) {
		return nil
	}
	var o decisionOut
	switch d.Behavior {
	case protocol.BehaviorAllow:
		o.Permission = "allow"
	case protocol.BehaviorDeny:
		msg := d.Message
		if msg == "" {
			msg = defaultDenyMsg
		}
		o = decisionOut{Permission: "deny", UserMessage: msg, AgentMessage: msg}
	default:
		return nil
	}
	b, _ := json.Marshal(o)
	return b
}
