package hookjson

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testBin = "/Users/x/Library/Application Support/PlatyNotch/bin/notch"

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func claudeSpec(path string) Spec {
	m := "startup"
	return Spec{Path: path, Format: FormatClaude, Entries: []Entry{
		{Event: "SessionStart", Matcher: &m, Command: Command(testBin, "claude-code", "session-start")},
		{Event: "Stop", Command: Command(testBin, "claude-code", "stop"), TimeoutSec: 120},
	}}
}

func writeTemp(t *testing.T, name string, data []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func canon(t *testing.T, b []byte) string {
	t.Helper()
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatalf("invalid json: %v\n%s", err, b)
	}
	out, _ := json.Marshal(v)
	return string(out)
}

func TestInstallPreservesUserHooks(t *testing.T) {
	orig := fixture(t, "claude_user.json")
	p := writeTemp(t, "settings.json", orig)
	changed, err := Install(claudeSpec(p))
	if err != nil || !changed {
		t.Fatalf("Install = %v, %v", changed, err)
	}
	got, _ := os.ReadFile(p)
	var top map[string]json.RawMessage
	if err := json.Unmarshal(got, &top); err != nil {
		t.Fatal(err)
	}
	if string(top["theme"]) != `"dark"` {
		t.Fatalf("theme lost: %s", got)
	}
	// Unknown top-level keys keep their order and content.
	if i, j, k := bytes.Index(got, []byte(`"theme"`)), bytes.Index(got, []byte(`"zeta"`)), bytes.Index(got, []byte(`"alpha"`)); !(i < j && j < k) {
		t.Fatalf("key order changed:\n%s", got)
	}
	var hooks map[string][]map[string]json.RawMessage
	if err := json.Unmarshal(top["hooks"], &hooks); err != nil {
		t.Fatal(err)
	}
	pre := hooks["PreToolUse"]
	if len(pre) != 1 || canon(t, pre[0]["hooks"]) != `[{"async":true,"command":"echo hook","type":"command"}]` {
		t.Fatalf("user hook changed: %s", top["hooks"])
	}
	if len(hooks["SessionStart"]) != 1 || len(hooks["Stop"]) != 1 {
		t.Fatalf("our hooks missing: %s", top["hooks"])
	}
	if !strings.Contains(string(hooks["SessionStart"][0]["matcher"]), "startup") {
		t.Fatalf("matcher missing")
	}
	ok, err := Installed(claudeSpec(p))
	if err != nil || !ok {
		t.Fatalf("Installed = %v, %v", ok, err)
	}
}

func TestInstallIsIdempotent(t *testing.T) {
	p := writeTemp(t, "settings.json", fixture(t, "claude_user.json"))
	if _, err := Install(claudeSpec(p)); err != nil {
		t.Fatal(err)
	}
	first, _ := os.ReadFile(p)
	changed, err := Install(claudeSpec(p))
	if err != nil || changed {
		t.Fatalf("second Install = %v, %v", changed, err)
	}
	second, _ := os.ReadFile(p)
	if !bytes.Equal(first, second) {
		t.Fatal("bytes changed on second install")
	}
}

func TestInstallReplacesStaleBinaryPath(t *testing.T) {
	p := writeTemp(t, "settings.json", fixture(t, "claude_user.json"))
	if _, err := Install(claudeSpec(p)); err != nil {
		t.Fatal(err)
	}
	s := claudeSpec(p)
	for i := range s.Entries {
		s.Entries[i].Command = strings.Replace(s.Entries[i].Command, "/Users/x/", "/Users/y/", 1)
	}
	changed, err := Install(s)
	if err != nil || !changed {
		t.Fatalf("Install = %v, %v", changed, err)
	}
	got, _ := os.ReadFile(p)
	if strings.Contains(string(got), "/Users/x/") || strings.Count(string(got), "hook claude-code") != 2 {
		t.Fatalf("stale or duplicated entries:\n%s", got)
	}
}

func TestUninstallRemovesOnlyOurs(t *testing.T) {
	orig := fixture(t, "claude_user.json")
	p := writeTemp(t, "settings.json", orig)
	if _, err := Install(claudeSpec(p)); err != nil {
		t.Fatal(err)
	}
	changed, err := Uninstall(claudeSpec(p))
	if err != nil || !changed {
		t.Fatalf("Uninstall = %v, %v", changed, err)
	}
	got, _ := os.ReadFile(p)
	if canon(t, got) != canon(t, orig) {
		t.Fatalf("not restored:\n%s", got)
	}
	changed, err = Uninstall(claudeSpec(p))
	if err != nil || changed {
		t.Fatalf("second Uninstall = %v, %v", changed, err)
	}
	ok, _ := Installed(claudeSpec(p))
	if ok {
		t.Fatal("still installed")
	}
}

func TestUninstallMissingFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "nope", "settings.json")
	changed, err := Uninstall(claudeSpec(p))
	if err != nil || changed {
		t.Fatalf("= %v, %v", changed, err)
	}
	if _, err := os.Stat(filepath.Dir(p)); err == nil {
		t.Fatal("Uninstall created directories")
	}
	if ok, err := Installed(claudeSpec(p)); ok || err != nil {
		t.Fatalf("Installed = %v, %v", ok, err)
	}
}

func TestInvalidJSONUntouched(t *testing.T) {
	bad := []byte(`{"hooks":`)
	p := writeTemp(t, "settings.json", bad)
	if _, err := Install(claudeSpec(p)); err == nil {
		t.Fatal("expected error")
	}
	if _, err := Uninstall(claudeSpec(p)); err == nil {
		t.Fatal("expected error from Uninstall")
	}
	got, _ := os.ReadFile(p)
	if !bytes.Equal(got, bad) {
		t.Fatalf("file modified: %s", got)
	}
	if _, err := os.Stat(p + ".platynotch-backup"); err == nil {
		t.Fatal("backup written")
	}
}

func TestWrongShapesRejected(t *testing.T) {
	for _, body := range []string{`[]`, `{"hooks":[]}`, `{"hooks":{"Stop":{}}}`} {
		p := writeTemp(t, "settings.json", []byte(body))
		if _, err := Install(claudeSpec(p)); err == nil {
			t.Errorf("%s: expected error", body)
		}
		got, _ := os.ReadFile(p)
		if string(got) != body {
			t.Errorf("%s: modified", body)
		}
	}
}

func TestMissingFileCreated(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a", "b", "settings.json")
	changed, err := Install(claudeSpec(p))
	if err != nil || !changed {
		t.Fatalf("= %v, %v", changed, err)
	}
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", st.Mode().Perm())
	}
	if _, err := os.Stat(p + ".platynotch-backup"); err == nil {
		t.Fatal("backup for a file that did not exist")
	}
	got, _ := os.ReadFile(p)
	canon(t, got)
}

func TestExistingModePreserved(t *testing.T) {
	p := writeTemp(t, "settings.json", fixture(t, "claude_user.json"))
	if err := os.Chmod(p, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := Install(claudeSpec(p)); err != nil {
		t.Fatal(err)
	}
	st, _ := os.Stat(p)
	if st.Mode().Perm() != 0o640 {
		t.Fatalf("mode = %v", st.Mode().Perm())
	}
	entries, _ := os.ReadDir(filepath.Dir(p))
	for _, e := range entries {
		if strings.Contains(e.Name(), "tmp") {
			t.Fatalf("temp file left behind: %s", e.Name())
		}
	}
}

func TestBackupWrittenOnce(t *testing.T) {
	orig := fixture(t, "claude_user.json")
	p := writeTemp(t, "settings.json", orig)
	if _, err := Install(claudeSpec(p)); err != nil {
		t.Fatal(err)
	}
	bak, err := os.ReadFile(p + ".platynotch-backup")
	if err != nil || !bytes.Equal(bak, orig) {
		t.Fatalf("backup = %q, %v", bak, err)
	}
	if _, err := Uninstall(claudeSpec(p)); err != nil {
		t.Fatal(err)
	}
	bak2, _ := os.ReadFile(p + ".platynotch-backup")
	if !bytes.Equal(bak2, orig) {
		t.Fatal("backup overwritten")
	}
}

func TestCommandQuotesSpaces(t *testing.T) {
	got := Command("/a b/notch", "claude-code", "stop")
	if got != `"/a b/notch" hook claude-code stop` {
		t.Fatalf("got %s", got)
	}
	if !IsOurs(got) {
		t.Fatal("IsOurs false")
	}
	if !IsOurs(Command(`/a "b"/notch`, "x", "y")) {
		t.Fatal("escaped quote path not recognised")
	}
}

func TestIsOurs(t *testing.T) {
	cases := map[string]bool{
		`"/a b/PlatyNotch/bin/notch" hook claude-code stop`: true,
		`/x/notch hook claude-code stop`:                    true,
		`"/x/notch-pro" hook codex stop`:                    true,
		`/x/notchy hook a b`:                                false,
		`/x/notch status`:                                   false,
		`echo hook`:                                         false,
		`echo /x/notch hook a b`:                            false,
		`/x/notch hook`:                                     false,
		``:                                                  false,
	}
	for c, want := range cases {
		if IsOurs(c) != want {
			t.Errorf("IsOurs(%q) = %v, want %v", c, !want, want)
		}
	}
}

func TestTimeoutWritten(t *testing.T) {
	p := filepath.Join(t.TempDir(), "s.json")
	if _, err := Install(claudeSpec(p)); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(p)
	if !strings.Contains(string(got), `"timeout": 120`) {
		t.Fatalf("no timeout:\n%s", got)
	}
	if strings.Count(string(got), `"timeout"`) != 1 {
		t.Fatalf("timeout written for entry without one:\n%s", got)
	}
}

func cursorSpec(path string) Spec {
	return Spec{Path: path, Format: FormatCursor, Entries: []Entry{
		{Event: "stop", Command: Command(testBin, "cursor", "stop")},
		{Event: "beforeShellExecution", Command: Command(testBin, "cursor", "before-shell"), TimeoutSec: 30},
	}}
}

func TestCursorFormat(t *testing.T) {
	orig := fixture(t, "cursor_user.json")
	p := writeTemp(t, "hooks.json", orig)
	if changed, err := Install(cursorSpec(p)); err != nil || !changed {
		t.Fatalf("= %v, %v", changed, err)
	}
	got, _ := os.ReadFile(p)
	var f struct {
		Version int                         `json:"version"`
		Hooks   map[string][]map[string]any `json:"hooks"`
	}
	if err := json.Unmarshal(got, &f); err != nil {
		t.Fatal(err)
	}
	if f.Version != 1 || len(f.Hooks["stop"]) != 1 || len(f.Hooks["beforeShellExecution"]) != 2 {
		t.Fatalf("bad shape:\n%s", got)
	}
	if f.Hooks["stop"][0]["command"] != Command(testBin, "cursor", "stop") || f.Hooks["stop"][0]["type"] != nil {
		t.Fatalf("entry shape wrong: %v", f.Hooks["stop"][0])
	}
	if f.Hooks["beforeShellExecution"][0]["command"] != "./audit.sh" {
		t.Fatal("user entry moved/changed")
	}
	if changed, _ := Install(cursorSpec(p)); changed {
		t.Fatal("not idempotent")
	}
	if ok, _ := Installed(cursorSpec(p)); !ok {
		t.Fatal("not installed")
	}
	if _, err := Uninstall(cursorSpec(p)); err != nil {
		t.Fatal(err)
	}
	got, _ = os.ReadFile(p)
	if canon(t, got) != canon(t, orig) {
		t.Fatalf("not restored:\n%s", got)
	}
}

func TestCursorNewFileGetsVersion(t *testing.T) {
	p := filepath.Join(t.TempDir(), "hooks.json")
	if _, err := Install(cursorSpec(p)); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(p)
	if !strings.Contains(string(got), `"version": 1`) {
		t.Fatalf("no version:\n%s", got)
	}
}

func TestCodexFormat(t *testing.T) {
	p := filepath.Join(t.TempDir(), "hooks.json")
	s := Spec{Path: p, Format: FormatCodex, Entries: []Entry{
		{Event: "Stop", Command: Command(testBin, "codex", "stop"), TimeoutSec: 5},
	}}
	if _, err := Install(s); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(p)
	want := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":` + mustJSON(Command(testBin, "codex", "stop")) + `,"timeout":5}]}]}}`
	if canon(t, got) != canon(t, []byte(want)) {
		t.Fatalf("got:\n%s", got)
	}
}

func mustJSON(s string) string { b, _ := json.Marshal(s); return string(b) }

// One malformed user-owned event must not block install, uninstall or the
// installed check; it is passed through untouched.
func TestMalformedForeignEventTolerated(t *testing.T) {
	for _, foreign := range []string{`{}`, `"x"`, `3`, `null`, `[1,"s",null,{"hooks":"nope"}]`} {
		body := `{"hooks":{"Foo":` + foreign + `,"PreToolUse":[{"hooks":[{"type":"command","command":"echo hook"}]}]}}`
		p := writeTemp(t, "settings.json", []byte(body))
		spec := claudeSpec(p)
		if ok, err := Installed(spec); err != nil || ok {
			t.Fatalf("%s: Installed before = %v, %v", foreign, ok, err)
		}
		if changed, err := Install(spec); err != nil || !changed {
			t.Fatalf("%s: Install = %v, %v", foreign, changed, err)
		}
		if ok, err := Installed(spec); err != nil || !ok {
			t.Fatalf("%s: Installed after = %v, %v", foreign, ok, err)
		}
		if ok, err := Installed(Spec{Path: p, Format: FormatClaude}); err != nil || !ok {
			t.Fatalf("%s: Installed(any) = %v, %v", foreign, ok, err)
		}
		got, _ := os.ReadFile(p)
		var top struct{ Hooks map[string]json.RawMessage }
		json.Unmarshal(got, &top)
		if canon(t, top.Hooks["Foo"]) != canon(t, []byte(foreign)) {
			t.Fatalf("%s: Foo changed: %s", foreign, top.Hooks["Foo"])
		}
		if changed, err := Uninstall(spec); err != nil || !changed {
			t.Fatalf("%s: Uninstall = %v, %v", foreign, changed, err)
		}
		got, _ = os.ReadFile(p)
		if canon(t, got) != canon(t, []byte(body)) {
			t.Fatalf("%s: not restored:\n%s", foreign, got)
		}
	}
}

// Install still refuses to overwrite one of its own events when that event
// holds a non-array value, and leaves the file untouched.
func TestInstallRejectsMalformedOwnEvent(t *testing.T) {
	body := `{"hooks":{"Stop":{"x":1}}}`
	p := writeTemp(t, "settings.json", []byte(body))
	if _, err := Install(claudeSpec(p)); err == nil {
		t.Fatal("expected error")
	}
	if got, _ := os.ReadFile(p); string(got) != body {
		t.Fatalf("modified: %s", got)
	}
	// Uninstall and Installed have nothing of ours to find there.
	if changed, err := Uninstall(claudeSpec(p)); err != nil || changed {
		t.Fatalf("Uninstall = %v, %v", changed, err)
	}
	if ok, err := Installed(claudeSpec(p)); err != nil || ok {
		t.Fatalf("Installed = %v, %v", ok, err)
	}
}
