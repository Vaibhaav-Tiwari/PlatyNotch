package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testBin = "/Users/me/Library/Application Support/PlatyNotch/bin/notch"

// fakeHome points every path at a temp home and PATH at an empty directory,
// so no test can see a real `claude` or touch the real home.
func fakeHome(t *testing.T) (home, binDir string) {
	t.Helper()
	home, binDir = t.TempDir(), t.TempDir()
	t.Setenv("PLATYNOTCH_USER_HOME", home)
	t.Setenv("PATH", binDir)
	return home, binDir
}

type ran struct {
	name string
	args []string
}

func recorder(calls *[]ran, err error) Runner {
	return func(_ context.Context, name string, args ...string) ([]byte, error) {
		*calls = append(*calls, ran{name, append([]string(nil), args...)})
		return nil, err
	}
}

func noRun(t *testing.T) Runner {
	return func(_ context.Context, name string, args ...string) ([]byte, error) {
		t.Fatalf("unexpected command %s %v", name, args)
		return nil, nil
	}
}

func readServers(t *testing.T, p string) map[string]json.RawMessage {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		MCPServers map[string]json.RawMessage `json:"mcpServers"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("%v\n%s", err, b)
	}
	return doc.MCPServers
}

func checkEntry(t *testing.T, raw json.RawMessage) {
	t.Helper()
	var e struct {
		Command string   `json:"command"`
		Args    []string `json:"args"`
	}
	if err := json.Unmarshal(raw, &e); err != nil || e.Command != testBin || len(e.Args) != 1 || e.Args[0] != "mcp" {
		t.Fatalf("entry %s (%v)", raw, err)
	}
}

func TestDesktopMergeKeepsOtherServers(t *testing.T) {
	home, _ := fakeHome(t)
	p := filepath.Join(home, "Library", "Application Support", "Claude", "claude_desktop_config.json")
	orig := `{"globalShortcut":"Cmd+K","mcpServers":{"fs":{"command":"npx","args":["fs"]}},"z":1}`
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(orig), 0o644); err != nil {
		t.Fatal(err)
	}
	msg, err := Install(context.Background(), ClientClaudeDesktop, testBin, noRun(t))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(msg, p) {
		t.Fatalf("message %q lacks path", msg)
	}
	s := readServers(t, p)
	if _, ok := s["fs"]; !ok || len(s) != 2 {
		t.Fatalf("servers %v", s)
	}
	checkEntry(t, s["platynotch"])
	b, _ := os.ReadFile(p)
	if i, j := strings.Index(string(b), `"globalShortcut"`), strings.Index(string(b), `"z"`); i < 0 || j < i {
		t.Fatalf("unrelated keys lost or reordered:\n%s", b)
	}
	if bak, _ := os.ReadFile(p + ".platynotch-backup"); string(bak) != orig {
		t.Fatalf("backup %q", bak)
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o644 {
		t.Fatalf("mode changed: %v", st.Mode())
	}

	if _, err := Uninstall(context.Background(), ClientClaudeDesktop, noRun(t)); err != nil {
		t.Fatal(err)
	}
	s = readServers(t, p)
	if _, ok := s["platynotch"]; ok || len(s) != 1 {
		t.Fatalf("after uninstall %v", s)
	}
}

func TestCursorCreatesFile(t *testing.T) {
	home, _ := fakeHome(t)
	p := filepath.Join(home, ".cursor", "mcp.json")
	if _, err := Install(context.Background(), ClientCursor, testBin, noRun(t)); err != nil {
		t.Fatal(err)
	}
	checkEntry(t, readServers(t, p)["platynotch"])
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", st.Mode())
	}
	if _, err := os.Stat(p + ".platynotch-backup"); !os.IsNotExist(err) {
		t.Fatalf("no backup expected for a new file: %v", err)
	}
	// Idempotent.
	if _, err := Install(context.Background(), ClientCursor, testBin, noRun(t)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p + ".platynotch-backup"); !os.IsNotExist(err) {
		t.Fatalf("unchanged reinstall wrote a backup: %v", err)
	}
}

func TestUninstallMissingFileIsNoop(t *testing.T) {
	home, _ := fakeHome(t)
	if _, err := Uninstall(context.Background(), ClientCursor, noRun(t)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, ".cursor")); !os.IsNotExist(err) {
		t.Fatal("uninstall created files")
	}
}

func TestClaudeCodeMissingCLIPrintsCommand(t *testing.T) {
	fakeHome(t) // PATH has no claude
	msg, err := Install(context.Background(), ClientClaudeCode, testBin, noRun(t))
	if err != nil {
		t.Fatal(err)
	}
	want := `claude mcp add --scope user platynotch -- '` + testBin + `' mcp`
	if !strings.Contains(msg, want) || !strings.Contains(msg, "not run") {
		t.Fatalf("message %q lacks %q", msg, want)
	}
	msg, err = Uninstall(context.Background(), ClientClaudeCode, noRun(t))
	if err != nil || !strings.Contains(msg, "claude mcp remove --scope user platynotch") {
		t.Fatalf("%q %v", msg, err)
	}
}

func installFakeClaude(t *testing.T, dir string) string {
	t.Helper()
	p := filepath.Join(dir, "claude")
	if err := os.WriteFile(p, []byte("#!/bin/sh\nexit 99\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestClaudeCodeRunsCLI(t *testing.T) {
	_, dir := fakeHome(t)
	claude := installFakeClaude(t, dir)
	var calls []ran
	msg, err := Install(context.Background(), ClientClaudeCode, testBin, recorder(&calls, nil))
	if err != nil {
		t.Fatal(err)
	}
	if len(calls) == 0 {
		t.Fatal("claude not run")
	}
	last := calls[len(calls)-1]
	want := []string{"mcp", "add", "--scope", "user", "platynotch", "--", testBin, "mcp"}
	if last.name != claude || strings.Join(last.args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("ran %s %q", last.name, last.args)
	}
	if strings.Contains(msg, "not run") {
		t.Fatalf("message %q", msg)
	}

	calls = nil
	if _, err := Uninstall(context.Background(), ClientClaudeCode, recorder(&calls, nil)); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 || strings.Join(calls[0].args, " ") != "mcp remove --scope user platynotch" {
		t.Fatalf("uninstall ran %v", calls)
	}
}

func TestClaudeCodeAddFailureIsError(t *testing.T) {
	_, dir := fakeHome(t)
	installFakeClaude(t, dir)
	if _, err := Install(context.Background(), ClientClaudeCode, testBin, recorder(&[]ran{}, errors.New("boom"))); err == nil {
		t.Fatal("expected error")
	}
}

func TestUnknownClient(t *testing.T) {
	fakeHome(t)
	if _, err := Install(context.Background(), "vscode", testBin, noRun(t)); err == nil {
		t.Fatal("expected error")
	}
	if _, err := Install(context.Background(), ClientCursor, "", noRun(t)); err == nil {
		t.Fatal("expected error for empty binary")
	}
}

func TestClaudeCodeUninstallNotRegisteredIsOK(t *testing.T) {
	_, dir := fakeHome(t)
	installFakeClaude(t, dir)
	run := func(context.Context, string, ...string) ([]byte, error) {
		return []byte("No user-scoped MCP server found with name: platynotch\n"), errors.New("exit status 1")
	}
	if msg, err := Uninstall(context.Background(), ClientClaudeCode, run); err != nil || !strings.Contains(msg, "not registered") {
		t.Fatalf("%q %v", msg, err)
	}
	fail := func(context.Context, string, ...string) ([]byte, error) {
		return []byte("config locked"), errors.New("exit status 1")
	}
	if _, err := Uninstall(context.Background(), ClientClaudeCode, fail); err == nil {
		t.Fatal("expected error")
	}
}
