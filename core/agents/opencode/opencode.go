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
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/opencode/hooks.go, activity.go.
//
// Modified for PlatyNotch: installs a user-level plugin (~/.config/opencode/plugin/platynotch.ts) instead of a workspace plugin; the plugin shells `notch hook opencode <event>` with the binary path injected into a template; no skill install, dependency stub or AO env.

// Package opencode is the OpenCode adapter. OpenCode has no command hooks,
// so installation writes a TypeScript plugin that reports lifecycle events.
package opencode

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/platynotch/platynotch/core/agents"
	"github.com/platynotch/platynotch/core/paths"
	"github.com/platynotch/platynotch/core/protocol"
)

const (
	agentID = "opencode"
	// OpenCode globs "{plugin,plugins}/*.{ts,js}" in every config dir (AO
	// hooks.go), so the global ~/.config/opencode/plugin/ is scanned.
	pluginFileName = "platynotch.ts"
	placeholder    = "__NOTCH_BIN__"
	// sentinel marks the file as ours; it must appear in the template.
	sentinel = "platynotch: managed opencode activity plugin"
)

//go:embed assets/platynotch.ts
var pluginTemplate string

func init() { agents.Register(Adapter{}) }

// Adapter implements agents.Adapter for OpenCode.
type Adapter struct{}

func (Adapter) ID() string   { return agentID }
func (Adapter) Name() string { return "OpenCode" }

func (Adapter) Detect() bool {
	if st, err := os.Stat(filepath.Join(paths.UserHome(), ".config", "opencode")); err == nil && st.IsDir() {
		return true
	}
	_, err := exec.LookPath("opencode")
	return err == nil
}

func (Adapter) ConfigPath() string {
	return filepath.Join(paths.UserHome(), ".config", "opencode", "plugin", pluginFileName)
}

// render injects hookBin as a JSON string literal (valid TypeScript even
// with spaces, quotes or backslashes in the path).
func render(hookBin string) (string, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(hookBin); err != nil {
		return "", err
	}
	lit := strings.TrimSuffix(buf.String(), "\n")
	if strings.Count(pluginTemplate, placeholder) != 1 {
		return "", errors.New("opencode: plugin template placeholder missing")
	}
	return strings.Replace(pluginTemplate, placeholder, lit, 1), nil
}

func readOurs(path string) (data []byte, exists, ours bool, err error) {
	data, err = os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, false, nil
	}
	if err != nil {
		return nil, false, false, err
	}
	return data, true, bytes.Contains(data, []byte(sentinel)), nil
}

// InstallHooks writes the plugin atomically. It refuses to overwrite a
// file at our path that we did not write.
func (a Adapter) InstallHooks(hookBin string) (bool, error) {
	want, err := render(hookBin)
	if err != nil {
		return false, err
	}
	path := a.ConfigPath()
	data, exists, ours, err := readOurs(path)
	if err != nil {
		return false, err
	}
	if exists && !ours {
		return false, fmt.Errorf("opencode: %s exists and is not managed by PlatyNotch", path)
	}
	if exists && string(data) == want {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return false, err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".platynotch-*.tmp")
	if err != nil {
		return false, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(want); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return false, err
	}
	return true, nil
}

// UninstallHooks removes only our own plugin file.
func (a Adapter) UninstallHooks() (bool, error) {
	path := a.ConfigPath()
	_, exists, ours, err := readOurs(path)
	if err != nil || !exists || !ours {
		return false, err
	}
	if err := os.Remove(path); err != nil {
		return false, err
	}
	return true, nil
}

func (a Adapter) HooksInstalled() (bool, error) {
	_, _, ours, err := readOurs(a.ConfigPath())
	return ours, err
}

// DeriveState maps the plugin's normalized events (AO opencode activity.go).
func (Adapter) DeriveState(event string, _ []byte) (protocol.State, bool) {
	switch event {
	case "session-start", "user-prompt-submit", "active":
		return protocol.StateActive, true
	case "stop":
		return protocol.StateIdle, true
	case "permission-blocked":
		return protocol.StateBlocked, true
	}
	return "", false
}

// ParseCommon reads the plugin's payload: session_id, cwd, prompt and the
// turn's final assistant text (as Message).
func (Adapter) ParseCommon(_ string, payload []byte) agents.Common {
	var p struct {
		SessionID            string `json:"session_id"`
		CWD                  string `json:"cwd"`
		Prompt               string `json:"prompt"`
		LastAssistantMessage string `json:"last_assistant_message"`
	}
	_ = json.Unmarshal(payload, &p)
	return agents.Common{SessionID: p.SessionID, CWD: p.CWD, Prompt: p.Prompt, Message: p.LastAssistantMessage}
}

func (Adapter) Approvals() agents.ApprovalSupport { return agents.ApprovalsNone }

func (Adapter) IsPermissionEvent(string) bool { return false }

func (Adapter) FormatDecision(string, protocol.HookDecision) []byte { return nil }
