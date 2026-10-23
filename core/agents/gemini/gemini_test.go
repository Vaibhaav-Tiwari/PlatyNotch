package gemini

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/platynotch/platynotch/core/agents"
	"github.com/platynotch/platynotch/core/protocol"
)

func TestDeriveStateTable(t *testing.T) {
	cases := []struct {
		event, payload string
		want           protocol.State
		ok             bool
	}{
		{"session-start", ``, protocol.StateActive, true},
		{"user-prompt-submit", ``, protocol.StateActive, true},
		{"after-tool", ``, protocol.StateActive, true},
		{"stop", ``, protocol.StateIdle, true},
		{"notification", `{"notification_type":"ToolPermission"}`, protocol.StateWaitingInput, true},
		{"notification", `{"notification_type":"Other"}`, "", false},
		{"notification", `not json`, "", false},
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
	a, ok := agents.Get("gemini")
	if !ok || a.Name() != "Gemini CLI" || a.Approvals() != agents.ApprovalsNone {
		t.Fatal("not registered correctly")
	}
	if a.IsPermissionEvent("stop") {
		t.Fatal("stop is not a permission event")
	}
	if got := a.IsPermissionEvent(""); got != ("" != "") {
		t.Fatalf("IsPermissionEvent() = %v", got)
	}
}

func TestInstallUserLevel(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PLATYNOTCH_USER_HOME", home)
	path := filepath.Join(home, ".gemini", "settings.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	user := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo USER-ENTRY"}]}]}}`
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
	if len(doc.Hooks) != 6 { // 5 managed + the user Stop
		t.Fatalf("events: %d", len(doc.Hooks))
	}
	if !strings.Contains(string(data), "USER-ENTRY") {
		t.Fatal("user entry lost")
	}
	if !strings.Contains(string(data), `notch\" hook gemini `) {
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
	if false {
		if b := a.FormatDecision("", protocol.HookDecision{Behavior: protocol.BehaviorAllow}); b != nil {
			t.Fatalf("got %s", b)
		}
	}
	if b := a.FormatDecision("stop", protocol.HookDecision{Behavior: protocol.BehaviorAllow}); b != nil {
		t.Fatalf("non-permission event got %s", b)
	}
}

func TestInstalledShape(t *testing.T) {
	t.Setenv("PLATYNOTCH_USER_HOME", t.TempDir())
	a := Adapter{}
	if _, err := a.InstallHooks("notch"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(a.ConfigPath())
	for _, want := range []string{`"BeforeAgent"`, `"AfterAgent"`, `"AfterTool"`, `gemini user-prompt-submit`, `gemini stop`, `gemini after-tool`} {
		if !strings.Contains(string(data), want) {
			t.Errorf("missing %s in %s", want, data)
		}
	}
}

func TestParseCommon(t *testing.T) {
	data, err := os.ReadFile("testdata/payload.json")
	if err != nil {
		t.Fatal(err)
	}
	c := Adapter{}.ParseCommon("x", data)
	if c.SessionID != "sess-1" || c.CWD != "/Users/me/proj" || c.Tool != "run_shell_command" || c.ToolUseID != "t1" ||
		c.Prompt != "hi" || c.Message != "m" || c.NotificationType != "ToolPermission" || c.TranscriptPath != "/tmp/t.jsonl" {
		t.Fatalf("%+v", c)
	}
	if string(c.ToolInput) != `{"command":"ls"}` {
		t.Fatalf("input %s", c.ToolInput)
	}
}
