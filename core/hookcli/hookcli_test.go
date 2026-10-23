package hookcli

import (
	"bytes"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "github.com/platynotch/platynotch/core/agents/all"
	"github.com/platynotch/platynotch/core/protocol"
	"github.com/platynotch/platynotch/core/wire"
)

func sockPath(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "pn")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return filepath.Join(d, "s")
}

func envFor(sock string) func(string) string {
	return func(k string) string {
		if k == "PLATYNOTCH_SOCKET" {
			return sock
		}
		return ""
	}
}

// fakeServer accepts one connection, reads hello + hook.event, calls handle.
func fakeServer(t *testing.T, sock string, handle func(w *wire.Writer, ev protocol.Envelope, c net.Conn)) {
	t.Helper()
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		r := wire.NewReader(c)
		hello, err := r.Read()
		if err != nil || hello.Type != protocol.TypeHello {
			return
		}
		ev, err := r.Read()
		if err != nil || ev.Type != protocol.TypeHookEvent {
			return
		}
		handle(wire.NewWriter(c), ev, c)
	}()
}

func run(t *testing.T, agent, event, stdin string, sock string) (string, int, time.Duration) {
	t.Helper()
	var out bytes.Buffer
	start := time.Now()
	code := Run(agent, event, strings.NewReader(stdin), &out, envFor(sock))
	return out.String(), code, time.Since(start)
}

func TestNoServerExitsQuietly(t *testing.T) {
	out, code, el := run(t, "claude-code", "permission-request", `{}`, sockPath(t))
	if code != 0 || out != "" || el > 500*time.Millisecond {
		t.Fatalf("code=%d out=%q el=%v", code, out, el)
	}
}

func TestStaleSocketFile(t *testing.T) {
	sock := sockPath(t)
	os.WriteFile(sock, []byte("x"), 0o600)
	out, code, el := run(t, "claude-code", "permission-request", `{}`, sock)
	if code != 0 || out != "" || el > 500*time.Millisecond {
		t.Fatalf("code=%d out=%q el=%v", code, out, el)
	}
}

func TestGarbageStdin(t *testing.T) {
	var got protocol.HookEvent
	sock := sockPath(t)
	ch := make(chan struct{})
	fakeServer(t, sock, func(w *wire.Writer, ev protocol.Envelope, c net.Conn) {
		ev.Decode(&got)
		w.Send(protocol.TypeHookAck, ev.ID, protocol.HookAck{})
		close(ch)
	})
	out, code, _ := run(t, "claude-code", "stop", strings.Repeat("x", 5<<20), sock)
	if code != 0 || out != "" {
		t.Fatalf("code=%d out=%q", code, out)
	}
	<-ch
	if got.Event != "stop" || got.Agent != "claude-code" || len(got.Payload) != 0 {
		t.Fatalf("got %+v", got)
	}
}

func TestUnknownAgent(t *testing.T) {
	out, code, _ := run(t, "nope", "stop", `{}`, sockPath(t))
	if code != 0 || out != "" {
		t.Fatalf("code=%d out=%q", code, out)
	}
}

func TestAllowPrinted(t *testing.T) {
	sock := sockPath(t)
	var got protocol.HookEvent
	fakeServer(t, sock, func(w *wire.Writer, ev protocol.Envelope, c net.Conn) {
		ev.Decode(&got)
		w.Send(protocol.TypeHookAck, ev.ID, protocol.HookAck{Wait: true, ApprovalID: "a1", TimeoutMS: 5000})
		time.Sleep(50 * time.Millisecond)
		w.Send(protocol.TypeHookDecision, ev.ID, protocol.HookDecision{Behavior: protocol.BehaviorAllow})
	})
	out, code, _ := run(t, "claude-code", "permission-request", `{"tool_name":"Bash"}`, sock)
	if code != 0 {
		t.Fatal(code)
	}
	if !got.WantDecision || string(got.Payload) != `{"tool_name":"Bash"}` {
		t.Fatalf("event %+v", got)
	}
	if !strings.HasSuffix(out, "\n") || !strings.Contains(out, `"allow"`) || !strings.Contains(out, "PermissionRequest") {
		t.Fatalf("out=%q", out)
	}
}

func TestWaitFalse(t *testing.T) {
	sock := sockPath(t)
	fakeServer(t, sock, func(w *wire.Writer, ev protocol.Envelope, c net.Conn) {
		w.Send(protocol.TypeHookAck, ev.ID, protocol.HookAck{Wait: false})
		time.Sleep(2 * time.Second)
	})
	out, code, el := run(t, "claude-code", "permission-request", `{}`, sock)
	if code != 0 || out != "" || el > time.Second {
		t.Fatalf("code=%d out=%q el=%v", code, out, el)
	}
}

func TestServerHangsUp(t *testing.T) {
	sock := sockPath(t)
	fakeServer(t, sock, func(w *wire.Writer, ev protocol.Envelope, c net.Conn) {
		w.Send(protocol.TypeHookAck, ev.ID, protocol.HookAck{Wait: true, TimeoutMS: 5000})
		time.Sleep(50 * time.Millisecond)
		c.Close()
	})
	out, code, el := run(t, "claude-code", "permission-request", `{}`, sock)
	if code != 0 || out != "" || el > 2*time.Second {
		t.Fatalf("code=%d out=%q el=%v", code, out, el)
	}
}

var _ = io.EOF

// Stdin over the limit is never forwarded as a decision request, even if the
// server (wrongly) answers with an allow.
func TestOversizeStdinNoDecisionRequest(t *testing.T) {
	sock := sockPath(t)
	var got protocol.HookEvent
	done := make(chan struct{})
	fakeServer(t, sock, func(w *wire.Writer, ev protocol.Envelope, c net.Conn) {
		ev.Decode(&got)
		w.Send(protocol.TypeHookAck, ev.ID, protocol.HookAck{Wait: true, TimeoutMS: 5000})
		w.Send(protocol.TypeHookDecision, ev.ID, protocol.HookDecision{Behavior: protocol.BehaviorAllow})
		close(done)
	})
	big := `{"tool_name":"Bash","tool_input":{"command":"` + strings.Repeat("a", maxStdin) + `"}}`
	out, code, _ := run(t, "claude-code", "permission-request", big, sock)
	if code != 0 || out != "" {
		t.Fatalf("code=%d out=%q", code, out)
	}
	<-done
	if got.WantDecision || len(got.Payload) != 0 {
		t.Fatalf("forwarded want=%v payload=%d bytes", got.WantDecision, len(got.Payload))
	}
}

// A maximal stdin still fits one wire line once wrapped in the envelope.
func TestMaxStdinFitsWire(t *testing.T) {
	if maxStdin > wire.MaxLine-(32<<10) {
		t.Fatalf("maxStdin %d leaves no room for the envelope under %d", maxStdin, wire.MaxLine)
	}
}

// A payload under the stdin limit that grows past a wire line once escaped
// (each '<' becomes <) is dropped together with the decision request.
func TestEscapedPayloadTooBigNoDecisionRequest(t *testing.T) {
	sock := sockPath(t)
	var got protocol.HookEvent
	done := make(chan struct{})
	fakeServer(t, sock, func(w *wire.Writer, ev protocol.Envelope, c net.Conn) {
		ev.Decode(&got)
		w.Send(protocol.TypeHookAck, ev.ID, protocol.HookAck{Wait: true, TimeoutMS: 5000})
		w.Send(protocol.TypeHookDecision, ev.ID, protocol.HookDecision{Behavior: protocol.BehaviorAllow})
		close(done)
	})
	big := `{"tool_name":"Bash","tool_input":{"command":"` + strings.Repeat("<", 1<<20) + `"}}`
	out, code, _ := run(t, "claude-code", "permission-request", big, sock)
	if code != 0 || out != "" {
		t.Fatalf("code=%d out=%q", code, out)
	}
	<-done
	if got.WantDecision || len(got.Payload) != 0 {
		t.Fatalf("forwarded want=%v payload=%d bytes", got.WantDecision, len(got.Payload))
	}
}

func TestAgentPID(t *testing.T) {
	names := map[int]string{100: "/bin/zsh", 101: "-zsh", 102: "node", 103: "bash", 104: "claude", 105: "fish", 106: "/usr/local/bin/codex", 107: "-sh", 108: "dash"}
	parents := map[int]int{100: 900, 101: 901, 103: 903, 105: 905, 107: 907, 108: 908}
	name := func(p int) string { return names[p] }
	parent := func(p int) int { return parents[p] }
	rows := []struct {
		claude string
		ppid   int
		want   int
	}{
		{"4242", 100, 4242}, // CLAUDE_PID wins
		{"", 102, 102},      // parent is the agent (sh -c exec'd it)
		{"", 104, 104},
		{"", 106, 106},
		{"", 100, 900}, // parent is a shell: step up one
		{"", 101, 901}, // login shell form
		{"", 103, 903},
		{"", 105, 905},
		{"", 107, 907},
		{"", 108, 908},
		{"x", 102, 102}, // junk CLAUDE_PID ignored
		{"", 1, 0},      // orphaned under launchd: unknown
	}
	for _, r := range rows {
		if got := agentPID(r.claude, r.ppid, name, parent); got != r.want {
			t.Errorf("agentPID(%q,%d)=%d want %d", r.claude, r.ppid, got, r.want)
		}
	}
	// A shell whose parent is unknown keeps the shell rather than 0.
	if got := agentPID("", 100, name, func(int) int { return 0 }); got != 100 {
		t.Errorf("unknown grandparent: got %d", got)
	}
}
