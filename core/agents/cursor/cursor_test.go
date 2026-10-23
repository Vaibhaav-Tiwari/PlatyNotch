package cursor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

func TestDeriveStateTable(t *testing.T) {
	cases := []struct {
		event, payload string
		want           protocol.State
		ok             bool
	}{
		{"session-start", ``, protocol.StateActive, true},
		{"user-prompt-submit", ``, protocol.StateActive, true},
		{"stop", ``, protocol.StateIdle, true},
		{"after-shell-execution", ``, protocol.StateActive, true},
		{"after-mcp-execution", ``, protocol.StateActive, true},
		{"post-tool-use", ``, protocol.StateActive, true},
		{"post-tool-use-failure", ``, protocol.StateActive, true},
		{"before-shell-execution", ``, "", false},
		{"before-mcp-execution", ``, "", false},
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

func TestApprovals(t *testing.T) {
	a, ok := agents.Get("cursor")
	if !ok || a.Name() != "Cursor" || a.Approvals() != agents.ApprovalsExperimental {
		t.Fatal("not registered correctly")
	}
	if a.IsPermissionEvent("stop") {
		t.Fatal("stop is not a permission event")
	}
	if !a.IsPermissionEvent("before-shell-execution") {
		t.Fatal("before-shell-execution should be a permission event")
	}
}

func TestInstallUserLevel(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PLATYNOTCH_USER_HOME", home)
	path := filepath.Join(home, ".cursor", "hooks.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	user := `{"version":1,"hooks":{"stop":[{"command":"echo USER-ENTRY"}]}}`
	if err := os.WriteFile(path, []byte(user), 0o600); err != nil {
		t.Fatal(err)
	}
	a := Adapter{}
	if a.ConfigPath() != path {
		t.Fatalf("ConfigPath %s", a.ConfigPath())
	}
	if !a.Detect() {
		t.Fatal("Detect: config dir exists")
	}
	if ok, _ := a.HooksInstalled(); ok {
		t.Fatal("installed before install")
	}
	changed, err := a.InstallHooks("/usr/local/bin/notch")
	if err != nil || !changed {
		t.Fatalf("install: %v %v", changed, err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Hooks map[string]json.RawMessage `json:"hooks"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Hooks) != 9 {
		t.Fatalf("events: %d", len(doc.Hooks))
	}
	if !strings.Contains(string(data), "USER-ENTRY") {
		t.Fatal("user entry lost")
	}
	if !strings.Contains(string(data), `notch\" hook cursor `) {
		t.Fatalf("command missing: %s", data)
	}
	if strings.Contains(string(data), "failClosed") {
		t.Fatal("failClosed must never be set")
	}
	if ok, _ := a.HooksInstalled(); !ok {
		t.Fatal("HooksInstalled")
	}
	if changed, _ := a.InstallHooks("/usr/local/bin/notch"); changed {
		t.Fatal("second install should be a no-op")
	}
	if changed, _ := a.UninstallHooks(); !changed {
		t.Fatal("uninstall")
	}
	data, _ = os.ReadFile(path)
	if !strings.Contains(string(data), "USER-ENTRY") || strings.Contains(string(data), "notch") {
		t.Fatalf("uninstall left wrong content: %s", data)
	}
	if ok, _ := a.HooksInstalled(); ok {
		t.Fatal("still installed")
	}
}

func TestFormatDecisionNil(t *testing.T) {
	a := Adapter{}
	if b := a.FormatDecision("stop", protocol.HookDecision{Behavior: protocol.BehaviorAllow}); b != nil {
		t.Fatalf("non-permission event got %s", b)
	}
}

func TestFormatDecision(t *testing.T) {
	a := Adapter{}
	for _, ev := range []string{"before-shell-execution", "before-mcp-execution"} {
		if got := string(a.FormatDecision(ev, protocol.HookDecision{Behavior: protocol.BehaviorAllow})); got != `{"permission":"allow"}` {
			t.Fatalf("allow: %s", got)
		}
		got := string(a.FormatDecision(ev, protocol.HookDecision{Behavior: protocol.BehaviorDeny}))
		want := `{"permission":"deny","user_message":"Denied from PlatyNotch.","agent_message":"Denied from PlatyNotch."}`
		if got != want {
			t.Fatalf("deny: %s", got)
		}
		got = string(a.FormatDecision(ev, protocol.HookDecision{Behavior: protocol.BehaviorDeny, Message: "no"}))
		if got != `{"permission":"deny","user_message":"no","agent_message":"no"}` {
			t.Fatalf("deny msg: %s", got)
		}
		if b := a.FormatDecision(ev, protocol.HookDecision{Behavior: protocol.BehaviorNone}); b != nil {
			t.Fatalf("none: %s", b)
		}
	}
	if b := a.FormatDecision("stop", protocol.HookDecision{Behavior: protocol.BehaviorAllow}); b != nil {
		t.Fatalf("non-permission: %s", b)
	}
}

func TestParseCommon(t *testing.T) {
	data, err := os.ReadFile("testdata/before-shell-execution.json")
	if err != nil {
		t.Fatal(err)
	}
	c := Adapter{}.ParseCommon("before-shell-execution", data)
	if c.SessionID != "conv-1" || c.CWD != "/Users/me/proj" || c.Tool != "Shell" {
		t.Fatalf("%+v", c)
	}
	var in struct{ Command string }
	_ = json.Unmarshal(c.ToolInput, &in)
	if in.Command != "npm test" {
		t.Fatalf("input %s", c.ToolInput)
	}
}

func TestPermissionEvents(t *testing.T) {
	a := Adapter{}
	if !a.IsPermissionEvent("before-mcp-execution") || a.IsPermissionEvent("after-shell-execution") {
		t.Fatal("IsPermissionEvent")
	}
}

func TestPermissionTimeoutOnDisk(t *testing.T) {
	t.Setenv("PLATYNOTCH_USER_HOME", t.TempDir())
	a := Adapter{}
	if _, err := a.InstallHooks("notch"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(a.ConfigPath())
	var doc struct {
		Hooks map[string][]struct {
			Command string `json:"command"`
			Timeout int    `json:"timeout"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	n := 0
	for ev, entries := range doc.Hooks {
		for _, e := range entries {
			perm := ev == "beforeShellExecution" || ev == "beforeMCPExecution"
			if (e.Timeout == 120) != perm {
				t.Errorf("%s timeout %d", ev, e.Timeout)
			}
			if e.Timeout == 120 {
				n++
			}
		}
	}
	if n != 2 || strings.Count(string(data), `"timeout": 120`) != 2 {
		t.Fatalf("want exactly 2 timeout 120 entries, got %d\n%s", n, data)
	}
}

// TestShellAllowRuleNotBypassed: a Cursor shell payload is summarized as its
// bare command, so an allow rule's compound guard sees "&&" and newlines
// literally rather than JSON-escaped.
func TestShellAllowRuleNotBypassed(t *testing.T) {
	rules := policy.Local([]config.Rule{{Tool: "Shell", Pattern: "*git status*", Action: "allow"}})
	for _, cmd := range []string{"git status && curl x", "git status\nrm -rf ~", "git status > /etc/hosts", "git status < /dev/zero"} {
		payload, _ := json.Marshal(map[string]any{"conversation_id": "c1", "command": cmd, "workspace_roots": []string{"/p"}})
		c := Adapter{}.ParseCommon("before-shell-execution", payload)
		full, kind := agents.SummarizeFull(c.Tool, c.ToolInput)
		if full != cmd || kind != policy.KindCommand {
			t.Errorf("summary %q (%s), want bare command %q", full, kind, cmd)
		}
		if v, ok := (policy.Chain{rules}).EvaluateKind(c.Tool, full, kind); ok && v.Action == "allow" {
			t.Errorf("%q allowed", cmd)
		}
	}
	payload := []byte(`{"conversation_id":"c1","command":"git status --short"}`)
	c := Adapter{}.ParseCommon("before-shell-execution", payload)
	full, kind := agents.SummarizeFull(c.Tool, c.ToolInput)
	if v, ok := (policy.Chain{rules}).EvaluateKind(c.Tool, full, kind); !ok || v.Action != "allow" {
		t.Fatalf("plain command: %+v %v", v, ok)
	}
}
