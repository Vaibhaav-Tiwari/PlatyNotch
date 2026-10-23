// Package e2e drives the real `notch` binary: `notch serve`, an agent hook and
// a UI client talking over the socket, exactly as Claude Code and the Mac app
// would.
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/platynotch/platynotch/core/protocol"
	"github.com/platynotch/platynotch/core/wire"
)

const (
	allowJSON = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` + "\n"
	denyJSON  = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"not now"}}}` + "\n"
	fixture   = "../agents/claudecode/testdata/permission-request.json"
)

var notchBin string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "notch-e2e")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	notchBin = filepath.Join(dir, "notch")
	build := exec.Command("go", "build", "-o", notchBin, "../cmd/notch")
	build.Stdout, build.Stderr = os.Stderr, os.Stderr
	if err := build.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "go build:", err)
		os.RemoveAll(dir)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

type env struct {
	home, user, sock string
	vars             []string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	sd, err := os.MkdirTemp("/tmp", "pn") // macOS socket paths are capped at 104 bytes
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(sd) })
	e := &env{home: t.TempDir(), user: t.TempDir(), sock: filepath.Join(sd, "n.sock")}
	e.vars = append(os.Environ(),
		"PLATYNOTCH_HOME="+e.home,
		"PLATYNOTCH_USER_HOME="+e.user,
		"PLATYNOTCH_SOCKET="+e.sock,
	)
	return e
}

func (e *env) cmd(args ...string) *exec.Cmd {
	c := exec.Command(notchBin, args...)
	c.Env = e.vars
	return c
}

// serve starts `notch serve`, waits for its socket and stops it (SIGTERM) at
// cleanup, checking that it exits 0 and removes the socket.
func (e *env) serve(t *testing.T) {
	t.Helper()
	c := e.cmd("serve")
	var stderr bytes.Buffer
	c.Stderr = &stderr
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- c.Wait() }()
	deadline := time.Now().Add(10 * time.Second)
	for {
		if nc, err := net.Dial("unix", e.sock); err == nil {
			nc.Close()
			break
		}
		select {
		case err := <-exited:
			t.Fatalf("notch serve exited early: %v\n%s", err, stderr.String())
		default:
		}
		if time.Now().After(deadline) {
			c.Process.Kill()
			t.Fatal("notch serve never listened")
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Cleanup(func() {
		c.Process.Signal(syscall.SIGTERM)
		select {
		case err := <-exited:
			if err != nil {
				t.Errorf("notch serve: %v\n%s", err, stderr.String())
			}
		case <-time.After(10 * time.Second):
			c.Process.Kill()
			t.Error("notch serve ignored SIGTERM")
		}
		if _, err := os.Lstat(e.sock); err == nil {
			t.Error("socket left behind after shutdown")
		}
	})
}

type ui struct {
	t  *testing.T
	nc net.Conn
	r  *wire.Reader
	w  *wire.Writer
}

// subscribeUI connects as the Mac app does: hello ui, subscribe, snapshot.
func (e *env) subscribeUI(t *testing.T) *ui {
	t.Helper()
	nc, err := net.Dial("unix", e.sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { nc.Close() })
	u := &ui{t: t, nc: nc, r: wire.NewReader(nc), w: wire.NewWriter(nc)}
	if err := u.w.Send(protocol.TypeHello, "", protocol.Hello{Role: protocol.RoleUI, Client: "e2e", Version: protocol.Version}); err != nil {
		t.Fatal(err)
	}
	if err := u.w.Send(protocol.TypeSubscribe, "s1", nil); err != nil {
		t.Fatal(err)
	}
	u.next(protocol.TypeSnapshot)
	return u
}

// next reads until a message of type typ arrives.
func (u *ui) next(typ string) protocol.Envelope {
	u.t.Helper()
	u.nc.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		env, err := u.r.Read()
		if err != nil {
			u.t.Fatalf("waiting for %s: %v", typ, err)
		}
		if env.Type == typ {
			return env
		}
	}
}

// startHook runs `notch hook claude-code permission-request` on the fixture.
func (e *env) startHook(t *testing.T) (c *exec.Cmd, stdout, stderr *bytes.Buffer) {
	t.Helper()
	in, err := os.Open(fixture)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { in.Close() })
	c = e.cmd("hook", "claude-code", "permission-request")
	stdout, stderr = &bytes.Buffer{}, &bytes.Buffer{}
	c.Stdin, c.Stdout, c.Stderr = in, stdout, stderr
	if err := c.Start(); err != nil {
		t.Fatal(err)
	}
	return c, stdout, stderr
}

func waitExit(t *testing.T, c *exec.Cmd, within time.Duration) int {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				return ee.ExitCode()
			}
			t.Fatal(err)
		}
		return 0
	case <-time.After(within):
		c.Process.Kill()
		t.Fatalf("%v did not exit within %v", c.Args, within)
		return -1
	}
}

func TestClaudePermissionEndToEnd(t *testing.T) {
	e := newEnv(t)
	e.serve(t)
	u := e.subscribeUI(t)

	hook, stdout, stderr := e.startHook(t)

	var appr protocol.Approval
	if err := u.next(protocol.TypeApprovalAdded).Decode(&appr); err != nil {
		t.Fatal(err)
	}
	if appr.Agent != "claude-code" || appr.Tool != "Bash" || appr.Summary != "npm test" {
		t.Fatalf("approval: %+v", appr)
	}
	if err := u.w.Send(protocol.TypeApprovalDecide, "d1", protocol.ApprovalDecide{ID: appr.ID, Behavior: protocol.BehaviorAllow}); err != nil {
		t.Fatal(err)
	}

	if code := waitExit(t, hook, 10*time.Second); code != 0 {
		t.Fatalf("hook exit %d, stderr %q", code, stderr.String())
	}
	if stdout.String() != allowJSON {
		t.Fatalf("hook stdout\n got %q\nwant %q", stdout.String(), allowJSON)
	}
	var res protocol.ApprovalResolved
	if err := u.next(protocol.TypeApprovalResolved).Decode(&res); err != nil {
		t.Fatal(err)
	}
	if res.ID != appr.ID || res.Behavior != protocol.BehaviorAllow || res.Source != "notch" {
		t.Fatalf("resolved: %+v", res)
	}
}

// With no UI subscribed the hook must not wait: the agent asks in its own
// terminal straight away.
func TestNoUINoWait(t *testing.T) {
	e := newEnv(t)
	e.serve(t)
	start := time.Now()
	hook, stdout, stderr := e.startHook(t)
	if code := waitExit(t, hook, 5*time.Second); code != 0 {
		t.Fatalf("hook exit %d, stderr %q", code, stderr.String())
	}
	if stdout.Len() != 0 || stderr.Len() != 0 {
		t.Fatalf("stdout %q stderr %q", stdout.String(), stderr.String())
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("hook took %v with no UI", d)
	}
}

// `notch status` shows the pending approval and `notch approve` answers it;
// neither CLI connection counts as a decider.
func TestCLIApprove(t *testing.T) {
	e := newEnv(t)
	e.serve(t)
	u := e.subscribeUI(t)
	hook, stdout, stderr := e.startHook(t)
	var appr protocol.Approval
	if err := u.next(protocol.TypeApprovalAdded).Decode(&appr); err != nil {
		t.Fatal(err)
	}

	out, err := e.cmd("status", "--json").Output()
	if err != nil {
		t.Fatalf("status --json: %v", err)
	}
	var snap protocol.Snapshot
	if err := json.Unmarshal(out, &snap); err != nil {
		t.Fatal(err)
	}
	if len(snap.Approvals) != 1 || snap.Approvals[0].ID != appr.ID {
		t.Fatalf("status approvals: %+v", snap.Approvals)
	}
	if out, err := e.cmd("status").Output(); err != nil || !strings.Contains(string(out), "npm test") {
		t.Fatalf("status: %v\n%s", err, out)
	}

	if out, err := e.cmd("approve", appr.ID, "deny", "--message", "not now").CombinedOutput(); err != nil {
		t.Fatalf("approve: %v\n%s", err, out)
	}
	if code := waitExit(t, hook, 10*time.Second); code != 0 {
		t.Fatalf("hook exit %d, stderr %q", code, stderr.String())
	}
	if stdout.String() != denyJSON {
		t.Fatalf("hook stdout\n got %q\nwant %q", stdout.String(), denyJSON)
	}
	var res protocol.ApprovalResolved
	if err := u.next(protocol.TypeApprovalResolved).Decode(&res); err != nil {
		t.Fatal(err)
	}
	if res.Behavior != protocol.BehaviorDeny || res.Source != "cli" {
		t.Fatalf("resolved: %+v", res)
	}
	// Answering again is an error (exit 1).
	c := e.cmd("approve", appr.ID, "allow")
	if err := c.Run(); c.ProcessState == nil || c.ProcessState.ExitCode() != 1 {
		t.Fatalf("second approve: %v", err)
	}
}

func TestVersion(t *testing.T) {
	e := newEnv(t)
	out, err := e.cmd("version").Output()
	if err != nil || string(out) != "notch dev (free)\n" {
		t.Fatalf("version: %v %q", err, out)
	}
}
