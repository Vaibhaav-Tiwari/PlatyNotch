package opencode

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

func setup(t *testing.T) (home, plugin string) {
	home = t.TempDir()
	t.Setenv("PLATYNOTCH_USER_HOME", home)
	return home, filepath.Join(home, ".config", "opencode", "plugin", "platynotch.ts")
}

func TestInstallWritesPlugin(t *testing.T) {
	_, plugin := setup(t)
	a := Adapter{}
	if a.ConfigPath() != plugin {
		t.Fatalf("ConfigPath %s", a.ConfigPath())
	}
	if ok, _ := a.HooksInstalled(); ok {
		t.Fatal("installed before install")
	}
	changed, err := a.InstallHooks("/usr/local/bin/notch")
	if err != nil || !changed {
		t.Fatalf("install: %v %v", changed, err)
	}
	b, err := os.ReadFile(plugin)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if !strings.Contains(s, `"/usr/local/bin/notch"`) {
		t.Fatal("binary path missing")
	}
	if strings.Contains(s, "__NOTCH_BIN__") {
		t.Fatal("placeholder left")
	}
	if ok, _ := a.HooksInstalled(); !ok {
		t.Fatal("not installed")
	}
	changed, err = a.InstallHooks("/usr/local/bin/notch")
	if err != nil || changed {
		t.Fatalf("second install should be a no-op: %v %v", changed, err)
	}
}

func TestInstallQuotesAwkwardPath(t *testing.T) {
	_, plugin := setup(t)
	bin := `/Users/a b/My "App"\bin/notch`
	if _, err := (Adapter{}).InstallHooks(bin); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(plugin)
	want := `const NOTCH_BIN: string = "/Users/a b/My \"App\"\\bin/notch"`
	if !strings.Contains(string(b), want) {
		t.Fatalf("literal not escaped, want %s", want)
	}
}

func TestInstallRefusesForeignFile(t *testing.T) {
	_, plugin := setup(t)
	os.MkdirAll(filepath.Dir(plugin), 0o755)
	os.WriteFile(plugin, []byte("// mine"), 0o600)
	if _, err := (Adapter{}).InstallHooks("/bin/notch"); err == nil {
		t.Fatal("expected error")
	}
	if b, _ := os.ReadFile(plugin); string(b) != "// mine" {
		t.Fatal("foreign file clobbered")
	}
	if ok, _ := (Adapter{}).HooksInstalled(); ok {
		t.Fatal("foreign file reported as ours")
	}
}

func TestUninstallRemovesOnlyOurFile(t *testing.T) {
	_, plugin := setup(t)
	a := Adapter{}
	if _, err := a.InstallHooks("/bin/notch"); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(filepath.Dir(plugin), "other.ts")
	os.WriteFile(other, []byte("export {}"), 0o600)
	changed, err := a.UninstallHooks()
	if err != nil || !changed {
		t.Fatalf("uninstall: %v %v", changed, err)
	}
	if _, err := os.Stat(plugin); !os.IsNotExist(err) {
		t.Fatal("plugin still present")
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatal("other plugin removed")
	}
	if changed, _ := a.UninstallHooks(); changed {
		t.Fatal("second uninstall should be a no-op")
	}
	// A foreign file at our path is never deleted.
	os.WriteFile(plugin, []byte("// mine"), 0o600)
	if changed, _ := a.UninstallHooks(); changed {
		t.Fatal("deleted foreign file")
	}
	if _, err := os.Stat(plugin); err != nil {
		t.Fatal("foreign file removed")
	}
}

func TestPluginWiresEveryEvent(t *testing.T) {
	// Each opencode event handled by the plugin must call the expected hook.
	cases := []struct{ marker, hook string }{
		{`case "session.created"`, "session-start"},
		{`case "message.updated"`, "session-start"},
		{`reportUserPrompt(sessionID, msg.id, "")`, ""},
		{`case "session.status"`, "stop"},
		{`case "permission.asked"`, "permission-blocked"},
		{`case "permission.replied"`, "active"},
		{`"tool.execute.before"`, "active"},
		{`"tool.execute.after"`, "active"},
	}
	for _, c := range cases {
		i := strings.Index(pluginTemplate, c.marker)
		if i < 0 {
			t.Errorf("marker %q missing", c.marker)
			continue
		}
		if c.hook == "" {
			continue
		}
		rest := pluginTemplate[i+len(c.marker):]
		// Only look up to the next handler so a neighbour cannot satisfy it.
		end := len(rest)
		for _, sep := range []string{"\n          }\n", `"tool.execute.`} {
			if j := strings.Index(rest, sep); j >= 0 && j < end {
				end = j
			}
		}
		if !strings.Contains(rest[:end], `callHook("`+c.hook+`"`) {
			t.Errorf("%s does not call hook %q", c.marker, c.hook)
		}
	}
	if !strings.Contains(pluginTemplate, `callHook("user-prompt-submit"`) {
		t.Error("user-prompt-submit never reported")
	}
	if !strings.Contains(pluginTemplate, `Bun.spawnSync([NOTCH_BIN, "hook", "opencode", hookName]`) {
		t.Error("hook command shape changed or not synchronous")
	}
	if strings.Contains(pluginTemplate, "AO_") {
		t.Error("AO-specific env left in template")
	}
}

func TestDeriveStateTable(t *testing.T) {
	cases := []struct {
		event string
		want  protocol.State
		ok    bool
	}{
		{"session-start", protocol.StateActive, true},
		{"user-prompt-submit", protocol.StateActive, true},
		{"active", protocol.StateActive, true},
		{"stop", protocol.StateIdle, true},
		{"permission-blocked", protocol.StateBlocked, true},
		{"bogus", "", false},
	}
	for _, c := range cases {
		got, ok := (Adapter{}).DeriveState(c.event, nil)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("%s: got (%q,%v) want (%q,%v)", c.event, got, ok, c.want, c.ok)
		}
	}
}

func TestParseCommonAndRegistration(t *testing.T) {
	a, ok := agents.Get("opencode")
	if !ok || a.Name() != "OpenCode" || a.Approvals() != agents.ApprovalsNone {
		t.Fatal("not registered correctly")
	}
	if a.IsPermissionEvent("permission-blocked") || a.FormatDecision("permission-blocked", protocol.HookDecision{Behavior: protocol.BehaviorAllow}) != nil {
		t.Fatal("opencode has no approvals")
	}
	c := a.ParseCommon("stop", []byte(`{"session_id":"s1","cwd":"/w","prompt":"hi","last_assistant_message":"done"}`))
	if c.SessionID != "s1" || c.CWD != "/w" || c.Prompt != "hi" || c.Message != "done" {
		t.Fatalf("%+v", c)
	}
}
