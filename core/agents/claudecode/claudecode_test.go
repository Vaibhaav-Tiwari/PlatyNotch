package claudecode

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

func TestDeriveStateTable(t *testing.T) {
	cases := []struct {
		event, payload string
		want           protocol.State
		ok             bool
	}{
		{"user-prompt-submit", ``, protocol.StateActive, true},
		{"pre-tool-use", ``, protocol.StateActive, true},
		{"permission-request", ``, protocol.StateBlocked, true},
		{"stop", ``, protocol.StateIdle, true},
		{"stop-failure", ``, protocol.StateIdle, true},
		{"notification", `{"notification_type":"idle_prompt"}`, protocol.StateIdle, true},
		{"notification", `{"notification_type":"agent_needs_input"}`, protocol.StateWaitingInput, true},
		{"notification", `{"notification_type":"permission_prompt"}`, protocol.StateBlocked, true},
		{"notification", `{"notification_type":"auth_success"}`, "", false},
		{"session-end", `{"reason":"clear"}`, "", false},
		{"session-end", `{"reason":"logout"}`, protocol.StateExited, true},
		{"bogus", ``, "", false},
	}
	a := Adapter{}
	for _, c := range cases {
		got, ok := a.DeriveState(c.event, []byte(c.payload))
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("%s %s: got (%q,%v) want (%q,%v)", c.event, c.payload, got, ok, c.want, c.ok)
		}
	}
}

func TestFormatDecisionAllow(t *testing.T) {
	got := string(Adapter{}.FormatDecision("permission-request", protocol.HookDecision{Behavior: protocol.BehaviorAllow}))
	want := `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
	if got != want {
		t.Fatalf("got %s", got)
	}
}

func TestFormatDecisionDeny(t *testing.T) {
	got := string(Adapter{}.FormatDecision("permission-request", protocol.HookDecision{Behavior: protocol.BehaviorDeny}))
	want := `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from PlatyNotch."}}}`
	if got != want {
		t.Fatalf("got %s", got)
	}
	got = string(Adapter{}.FormatDecision("permission-request", protocol.HookDecision{Behavior: protocol.BehaviorDeny, Message: "no"}))
	if !strings.Contains(got, `"message":"no"`) {
		t.Fatalf("got %s", got)
	}
}

func TestFormatDecisionNone(t *testing.T) {
	a := Adapter{}
	if b := a.FormatDecision("permission-request", protocol.HookDecision{Behavior: protocol.BehaviorNone}); b != nil {
		t.Fatalf("got %s", b)
	}
	if b := a.FormatDecision("stop", protocol.HookDecision{Behavior: protocol.BehaviorAllow}); b != nil {
		t.Fatalf("non-permission event got %s", b)
	}
}

func TestParseCommon(t *testing.T) {
	data, err := os.ReadFile("testdata/permission-request.json")
	if err != nil {
		t.Fatal(err)
	}
	c := Adapter{}.ParseCommon("permission-request", data)
	if c.SessionID != "sess-123" || c.CWD != "/Users/me/proj" || c.Tool != "Bash" || c.ToolUseID != "toolu_01" {
		t.Fatalf("%+v", c)
	}
	var in struct{ Command string }
	_ = json.Unmarshal(c.ToolInput, &in)
	if in.Command != "npm test" {
		t.Fatalf("input %s", c.ToolInput)
	}
}

func TestRegisteredAndVerified(t *testing.T) {
	a, ok := agents.Get("claude-code")
	if !ok || a.Approvals() != agents.ApprovalsVerified || a.Name() != "Claude Code" {
		t.Fatal("not registered correctly")
	}
	if !a.IsPermissionEvent("permission-request") || a.IsPermissionEvent("stop") {
		t.Fatal("IsPermissionEvent")
	}
}

func TestInstallUserLevel(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PLATYNOTCH_USER_HOME", home)
	a := Adapter{}
	if a.Detect() == false && false {
		t.Fatal()
	}
	changed, err := a.InstallHooks("/usr/local/bin/notch")
	if err != nil || !changed {
		t.Fatalf("install: %v %v", changed, err)
	}
	path := filepath.Join(home, ".claude", "settings.json")
	if a.ConfigPath() != path {
		t.Fatalf("ConfigPath %s", a.ConfigPath())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
				Timeout int    `json:"timeout"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Hooks) != 12 {
		t.Fatalf("events: %d", len(doc.Hooks))
	}
	if n := strings.Count(string(data), `"timeout":120`) + strings.Count(string(data), `"timeout": 120`); n != 1 {
		t.Fatalf("timeout 120 count %d", n)
	}
	for ev, groups := range doc.Hooks {
		for _, g := range groups {
			for _, h := range g.Hooks {
				if (h.Timeout == 120) != (ev == "PermissionRequest") {
					t.Errorf("%s timeout %d", ev, h.Timeout)
				}
			}
		}
	}
	if ok, _ := a.HooksInstalled(); !ok {
		t.Fatal("HooksInstalled")
	}
	if !strings.Contains(string(data), "claude-code permission-request") {
		t.Fatal("command missing")
	}
	if changed, _ := a.UninstallHooks(); !changed {
		t.Fatal("uninstall")
	}
	if ok, _ := a.HooksInstalled(); ok {
		t.Fatal("still installed")
	}
}
