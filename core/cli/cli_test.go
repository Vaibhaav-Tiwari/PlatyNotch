package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// env points every PlatyNotch path at temp dirs. The socket lives under /tmp
// because macOS caps socket paths at 104 bytes.
func env(t *testing.T) (home, user, sock string) {
	t.Helper()
	home, user = t.TempDir(), t.TempDir()
	sd, err := os.MkdirTemp("/tmp", "pn")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(sd) })
	sock = filepath.Join(sd, "n.sock")
	t.Setenv("PLATYNOTCH_HOME", home)
	t.Setenv("PLATYNOTCH_USER_HOME", user)
	t.Setenv("PLATYNOTCH_SOCKET", sock)
	return home, user, sock
}

type result struct {
	code           int
	stdout, stderr string
}

func run(t *testing.T, stdin string, args []string, opts ...Option) result {
	t.Helper()
	var out, errb bytes.Buffer
	opts = append(opts, WithIO(strings.NewReader(stdin), &out, &errb))
	code := Run(context.Background(), args, opts...)
	return result{code, out.String(), errb.String()}
}

type jsonRow struct {
	ID        string `json:"id"`
	Detected  bool   `json:"detected"`
	Installed bool   `json:"installed"`
}

func hooksStatus(t *testing.T) map[string]jsonRow {
	t.Helper()
	r := run(t, "", []string{"hooks", "status", "--json"})
	if r.code != 0 {
		t.Fatalf("hooks status: %d %s", r.code, r.stderr)
	}
	var list []jsonRow
	if err := json.Unmarshal([]byte(r.stdout), &list); err != nil {
		t.Fatalf("hooks status --json: %v\n%s", err, r.stdout)
	}
	m := map[string]jsonRow{}
	for _, a := range list {
		m[a.ID] = a
	}
	return m
}

func TestHooksStatusJSON(t *testing.T) {
	env(t)
	if st := hooksStatus(t); len(st) < 6 || st["claude-code"].Installed {
		t.Fatalf("before install: %+v", st)
	}
	if r := run(t, "", []string{"hooks", "install", "claude-code"}); r.code != 0 {
		t.Fatalf("hooks install: %d %s", r.code, r.stderr)
	}
	st := hooksStatus(t)
	if !st["claude-code"].Installed {
		t.Fatalf("claude-code not installed: %+v", st)
	}
	if st["codex"].Installed {
		t.Fatalf("codex installed too: %+v", st)
	}
	if r := run(t, "", []string{"hooks", "uninstall", "claude-code"}); r.code != 0 {
		t.Fatalf("hooks uninstall: %d %s", r.code, r.stderr)
	}
	if hooksStatus(t)["claude-code"].Installed {
		t.Fatal("still installed after uninstall")
	}
}

func TestHooksInstallLinksHookBinary(t *testing.T) {
	_, user, _ := env(t)
	if r := run(t, "", []string{"hooks", "install", "claude-code"}); r.code != 0 {
		t.Fatalf("hooks install: %d %s", r.code, r.stderr)
	}
	bin := paths.HookBinary()
	st, err := os.Lstat(bin)
	if err != nil || st.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("hook binary is not a symlink: %v %v", st, err)
	}
	target, _ := os.Readlink(bin)
	exe, _ := os.Executable()
	exe, _ = filepath.EvalSymlinks(exe)
	if target != exe {
		t.Fatalf("symlink -> %q, want %q", target, exe)
	}
	if dst, _ := os.Stat(filepath.Dir(bin)); dst.Mode().Perm() != 0o700 {
		t.Fatalf("bin dir mode %v", dst.Mode().Perm())
	}
	settings, _ := os.ReadFile(filepath.Join(user, ".claude", "settings.json"))
	if !strings.Contains(string(settings), bin) {
		t.Fatalf("settings do not reference %s:\n%s", bin, settings)
	}
}

func TestHooksInstallKeepsExistingBinary(t *testing.T) {
	env(t)
	bin := paths.HookBinary()
	if err := os.MkdirAll(filepath.Dir(bin), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bin, []byte("app binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	if r := run(t, "", []string{"hooks", "install", "claude-code"}); r.code != 0 {
		t.Fatalf("hooks install: %d %s", r.code, r.stderr)
	}
	if b, _ := os.ReadFile(bin); string(b) != "app binary" {
		t.Fatalf("existing hook binary overwritten: %q", b)
	}
}

func TestHooksUsageErrors(t *testing.T) {
	env(t)
	for _, args := range [][]string{
		{"hooks"}, {"hooks", "bogus"}, {"hooks", "install", "no-such-agent"},
	} {
		if r := run(t, "", args); r.code != 2 || r.stderr == "" {
			t.Errorf("%v: code %d stderr %q", args, r.code, r.stderr)
		}
	}
}

func TestUnknownCommand(t *testing.T) {
	env(t)
	r := run(t, "", []string{"frobnicate"})
	if r.code != 2 {
		t.Fatalf("exit %d, want 2", r.code)
	}
	if !strings.Contains(r.stderr, "usage: notch") || !strings.Contains(r.stderr, "serve") || r.stdout != "" {
		t.Fatalf("stderr %q stdout %q", r.stderr, r.stdout)
	}
	if r := run(t, "", nil); r.code != 2 || !strings.Contains(r.stderr, "usage: notch") {
		t.Fatalf("no args: %+v", r)
	}
	if r := run(t, "", []string{"help"}); r.code != 0 || !strings.Contains(r.stdout, "usage: notch") {
		t.Fatalf("help: %+v", r)
	}
}

func TestWithCommandsAddsCommand(t *testing.T) {
	env(t)
	var got []string
	pair := Command{Summary: "pair a phone", Run: func(ctx context.Context, args []string) int {
		got = args
		return 7
	}}
	opt := WithCommands(map[string]Command{"pair": pair})
	r := run(t, "", []string{"pair", "a", "b"}, opt)
	if r.code != 7 || strings.Join(got, ",") != "a,b" {
		t.Fatalf("pair: code %d args %v", r.code, got)
	}
	if r := run(t, "", []string{"help"}, opt); !strings.Contains(r.stdout, "pair a phone") {
		t.Fatalf("usage lacks pair: %q", r.stdout)
	}
}

func TestVersion(t *testing.T) {
	env(t)
	if r := run(t, "", []string{"version"}); r.code != 0 || r.stdout != "notch dev (free)\n" {
		t.Fatalf("version: %+v", r)
	}
	if r := run(t, "", []string{"version"}, WithEdition("pro")); r.stdout != "notch dev (pro)\n" {
		t.Fatalf("version pro: %+v", r)
	}
}

func TestHookAlwaysExitsZero(t *testing.T) {
	env(t) // nothing listening on the socket
	for _, args := range [][]string{
		{"hook"}, {"hook", "claude-code"}, {"hook", "claude-code", "permission-request"},
		{"hook", "nope", "x", "y"},
	} {
		r := run(t, `{"session_id":"s"}`, args)
		if r.code != 0 || r.stdout != "" || r.stderr != "" {
			t.Errorf("%v: %+v", args, r)
		}
	}
}

func TestStatuslineAlwaysExitsZero(t *testing.T) {
	home, _, _ := env(t)
	in := `{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":12}}}`
	r := run(t, in, []string{"statusline"})
	if r.code != 0 || r.stdout == "" {
		t.Fatalf("statusline: %+v", r)
	}
	if _, err := os.Stat(filepath.Join(home, "usage.json")); err != nil {
		t.Fatalf("usage.json not written: %v", err)
	}
	if r := run(t, "not json", []string{"statusline"}); r.code != 0 {
		t.Fatalf("statusline bad input: %+v", r)
	}
}

func TestStatuslineInstallUninstall(t *testing.T) {
	_, user, _ := env(t)
	if r := run(t, "", []string{"statusline", "install"}); r.code != 0 {
		t.Fatalf("install: %+v", r)
	}
	b, _ := os.ReadFile(filepath.Join(user, ".claude", "settings.json"))
	if !strings.Contains(string(b), paths.HookBinary()) || !strings.Contains(string(b), "statusline") {
		t.Fatalf("settings: %s", b)
	}
	if r := run(t, "", []string{"statusline", "uninstall"}); r.code != 0 {
		t.Fatalf("uninstall: %+v", r)
	}
	b, _ = os.ReadFile(filepath.Join(user, ".claude", "settings.json"))
	if strings.Contains(string(b), "statusline") {
		t.Fatalf("statusline left behind: %s", b)
	}
	if r := run(t, "", []string{"statusline", "bogus"}); r.code != 2 {
		t.Fatalf("bogus: %+v", r)
	}
}

func TestStatusAndApproveWithoutCore(t *testing.T) {
	env(t)
	r := run(t, "", []string{"status"})
	if r.code != 1 || !strings.Contains(r.stderr, "not running") {
		t.Fatalf("status: %+v", r)
	}
	r = run(t, "", []string{"approve", "a1", "allow"})
	if r.code != 1 || !strings.Contains(r.stderr, "not running") {
		t.Fatalf("approve: %+v", r)
	}
}

func TestApproveUsage(t *testing.T) {
	env(t)
	for _, args := range [][]string{
		{"approve"}, {"approve", "a1"}, {"approve", "a1", "maybe"},
		{"approve", "a1", "deny", "--message"}, {"approve", "a1", "allow", "extra"},
		{"status", "--yaml"},
	} {
		if r := run(t, "", args); r.code != 2 || r.stderr == "" {
			t.Errorf("%v: %+v", args, r)
		}
	}
}

// startServe runs `notch serve` in-process and waits for the socket.
func startServe(t *testing.T, sock string) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan int, 1)
	go func() {
		done <- Run(ctx, []string{"serve"}, WithIO(strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{}))
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if c, err := net.Dial("unix", sock); err == nil {
			c.Close()
			break
		}
		select {
		case code := <-done:
			t.Fatalf("serve exited early: %d", code)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("serve never listened")
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Cleanup(func() {
		cancel()
		select {
		case code := <-done:
			if code != 0 {
				t.Errorf("serve exit %d", code)
			}
		case <-time.After(5 * time.Second):
			t.Error("serve did not stop")
		}
	})
}

func TestServeStatusApprove(t *testing.T) {
	home, _, sock := env(t)
	startServe(t, sock)

	r := run(t, "", []string{"status", "--json"})
	if r.code != 0 {
		t.Fatalf("status --json: %+v", r)
	}
	var snap protocol.Snapshot
	if err := json.Unmarshal([]byte(r.stdout), &snap); err != nil || snap.Edition != "free" {
		t.Fatalf("snapshot %v: %q", err, r.stdout)
	}
	if r := run(t, "", []string{"status"}); r.code != 0 || !strings.Contains(r.stdout, "No sessions") {
		t.Fatalf("status: %+v", r)
	}
	r = run(t, "", []string{"approve", "nope", "allow"})
	if r.code != 1 || !strings.Contains(r.stderr, "nope") {
		t.Fatalf("approve unknown id: %+v", r)
	}
	if _, err := os.Stat(filepath.Join(home, "logs", "core.log")); err != nil {
		t.Fatalf("core.log: %v", err)
	}
	// A second serve on the same socket fails as a runtime error.
	if r := run(t, "", []string{"serve"}); r.code != 1 || !strings.Contains(r.stderr, "already running") {
		t.Fatalf("second serve: %+v", r)
	}
}

func TestDoctor(t *testing.T) {
	_, user, sock := env(t)
	if err := os.MkdirAll(filepath.Join(user, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	r := run(t, "", []string{"doctor"})
	if r.code != 1 || !strings.Contains(r.stdout, "not running") {
		t.Fatalf("doctor without core: %+v", r)
	}
	for _, want := range []string{"Claude Code", "Codex", "hook trust", "statusline", "config"} {
		if !strings.Contains(r.stdout, want) {
			t.Errorf("doctor output lacks %q:\n%s", want, r.stdout)
		}
	}
	startServe(t, sock)
	if r := run(t, "", []string{"doctor"}); r.code != 0 || !strings.Contains(r.stdout, "reachable") {
		t.Fatalf("doctor with core: %+v", r)
	}
}

// A hook link left pointing into a deleted app bundle (a rebuilt or removed
// PlatyNotch.app) breaks every hook and the Claude status line, so Claude's limits
// never reach usage.json. Doctor names it as a failure and says how to fix it.
func TestDoctorDanglingHookBinary(t *testing.T) {
	_, user, _ := env(t)
	if err := os.MkdirAll(filepath.Join(user, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	link := paths.HookBinary()
	if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
		t.Fatal(err)
	}
	gone := filepath.Join(t.TempDir(), "Old.app", "Contents", "MacOS", "notch")
	if err := os.Symlink(gone, link); err != nil {
		t.Fatal(err)
	}
	r := run(t, "", []string{"doctor"})
	if !strings.Contains(r.stdout, "FAIL  hook binary "+link+" points at "+gone+", which no longer exists") ||
		!strings.Contains(r.stdout, "open PlatyNotch") {
		t.Fatalf("doctor output:\n%s", r.stdout)
	}
}
