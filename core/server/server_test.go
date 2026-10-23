package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/ext"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/wire"
)

// shortDir returns a temp dir short enough for a Unix socket path (macOS caps
// them at 104 bytes; t.TempDir() can be longer).
func shortDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "pn")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

type testServer struct {
	*Server
	sock string
}

func start(t *testing.T, o Options) *testServer {
	t.Helper()
	if o.Socket == "" {
		o.Socket = filepath.Join(shortDir(t), "n.sock")
	}
	s, err := New(o)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	errc := make(chan error, 1)
	go func() { errc <- s.Serve(ctx) }()
	deadline := time.Now().Add(3 * time.Second)
	for {
		c, err := net.Dial("unix", o.Socket)
		if err == nil {
			c.Close()
			break
		}
		select {
		case err := <-errc:
			t.Fatalf("Serve returned early: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("server never listened: %v", err)
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Cleanup(func() {
		cancel()
		select {
		case err := <-errc:
			if err != nil {
				t.Errorf("Serve: %v", err)
			}
		case <-time.After(3 * time.Second):
			buf := make([]byte, 1<<20)
			t.Errorf("Serve did not return after cancel\n%s", buf[:runtime.Stack(buf, true)])
		}
	})
	return &testServer{Server: s, sock: o.Socket}
}

type client struct {
	t    *testing.T
	conn net.Conn
	r    *wire.Reader
	w    *wire.Writer
}

func dial(t *testing.T, sock, role string) *client {
	t.Helper()
	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	c := &client{t: t, conn: conn, r: wire.NewReader(conn), w: wire.NewWriter(conn)}
	c.send(protocol.TypeHello, "", protocol.Hello{Role: role, Client: "test", Version: protocol.Version})
	return c
}

func (c *client) send(typ, id string, data any) {
	c.t.Helper()
	if err := c.w.Send(typ, id, data); err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) next(timeout time.Duration) (protocol.Envelope, error) {
	c.conn.SetReadDeadline(time.Now().Add(timeout))
	return c.r.Read()
}

// waitFor reads until an envelope of type typ arrives (2 s budget).
func (c *client) waitFor(typ string) protocol.Envelope {
	c.t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		env, err := c.next(time.Until(deadline))
		if err != nil {
			c.t.Fatalf("waiting for %s: %v", typ, err)
		}
		if env.Type == typ {
			return env
		}
	}
}

func decode[T any](t *testing.T, env protocol.Envelope) T {
	t.Helper()
	var v T
	if err := env.Decode(&v); err != nil {
		t.Fatalf("decode %s: %v", env.Type, err)
	}
	return v
}

func subscribe(t *testing.T, sock string) (*client, protocol.Snapshot) {
	t.Helper()
	ui := dial(t, sock, protocol.RoleUI)
	ui.send(protocol.TypeSubscribe, "sub", nil)
	env := ui.waitFor(protocol.TypeSnapshot)
	if env.ID != "sub" {
		t.Fatalf("snapshot id %q", env.ID)
	}
	return ui, decode[protocol.Snapshot](t, env)
}

func claudeEvent(event, sid, payload string, want bool) protocol.HookEvent {
	return protocol.HookEvent{
		Agent: "claude-code", Event: event, Payload: json.RawMessage(payload),
		CWD: "/tmp/proj", WantDecision: want, At: time.Now().UTC(),
	}
}

func permission(sid, command string) protocol.HookEvent {
	p, _ := json.Marshal(map[string]any{
		"session_id": sid, "cwd": "/tmp/proj", "tool_name": "Bash",
		"tool_use_id": "tu_1", "tool_input": map[string]string{"command": command},
	})
	return claudeEvent("permission-request", sid, string(p), true)
}

// hook sends one hook event and returns the connection for reading replies.
func hook(t *testing.T, sock string, ev protocol.HookEvent) *client {
	t.Helper()
	h := dial(t, sock, protocol.RoleHook)
	h.send(protocol.TypeHookEvent, "h1", ev)
	return h
}

func readAck(t *testing.T, h *client) protocol.HookAck {
	t.Helper()
	env := h.waitFor(protocol.TypeHookAck)
	if env.ID != "h1" {
		t.Fatalf("ack id %q", env.ID)
	}
	return decode[protocol.HookAck](t, env)
}

func readDecision(t *testing.T, h *client) protocol.HookDecision {
	t.Helper()
	env := h.waitFor(protocol.TypeHookDecision)
	if env.ID != "h1" {
		t.Fatalf("decision id %q", env.ID)
	}
	return decode[protocol.HookDecision](t, env)
}

func TestSocketModeAndPeer(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	st, err := os.Stat(s.sock)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode()&os.ModeSocket == 0 || st.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %v", st.Mode())
	}
	// Same-uid peers pass the peer check.
	c := dial(t, s.sock, protocol.RoleCLI)
	c.send(protocol.TypePing, "p1", nil)
	if env := c.waitFor(protocol.TypePong); env.ID != "p1" {
		t.Fatalf("pong id %q", env.ID)
	}
}

func TestSnapshotOnSubscribe(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	h := hook(t, s.sock, claudeEvent("user-prompt-submit", "s1", `{"session_id":"s1","cwd":"/tmp/proj","prompt":"fix it"}`, false))
	if ack := readAck(t, h); ack.Wait {
		t.Fatal("plain event asked to wait")
	}
	_, snap := subscribe(t, s.sock)
	if snap.Edition != "free" {
		t.Fatalf("edition %q", snap.Edition)
	}
	if snap.Memory.Enabled {
		t.Fatal("memory enabled without a service")
	}
	if snap.Approvals == nil || snap.Loops == nil {
		t.Fatal("nil slices in snapshot")
	}
	if len(snap.Sessions) != 1 || snap.Sessions[0].Key != "claude-code:s1" ||
		snap.Sessions[0].State != protocol.StateActive || snap.Sessions[0].Title != "fix it" {
		t.Fatalf("sessions %+v", snap.Sessions)
	}
}

func TestApprovalRoundTrip(t *testing.T) {
	var mu sync.Mutex
	var audits []ext.AuditEvent
	s := start(t, Options{Config: config.Default()})
	s.AddAuditor(auditFunc(func(e ext.AuditEvent) { mu.Lock(); audits = append(audits, e); mu.Unlock() }))
	ui, _ := subscribe(t, s.sock)

	h := hook(t, s.sock, permission("s1", "npm test"))
	ack := readAck(t, h)
	if !ack.Wait || ack.ApprovalID == "" || ack.TimeoutMS != 100000 {
		t.Fatalf("ack %+v", ack)
	}
	added := decode[protocol.Approval](t, ui.waitFor(protocol.TypeApprovalAdded))
	if added.ID != ack.ApprovalID || added.Summary != "npm test" || added.Tool != "Bash" ||
		added.SessionKey != "claude-code:s1" || added.Project != "proj" {
		t.Fatalf("approval %+v", added)
	}
	if p := s.Snapshot().Approvals; len(p) != 1 {
		t.Fatalf("pending %+v", p)
	}

	ui.send(protocol.TypeApprovalDecide, "d1", protocol.ApprovalDecide{ID: added.ID, Behavior: protocol.BehaviorAllow})
	if d := readDecision(t, h); d.Behavior != protocol.BehaviorAllow || d.Source != "notch" {
		t.Fatalf("decision %+v", d)
	}
	res := decode[protocol.ApprovalResolved](t, ui.waitFor(protocol.TypeApprovalResolved))
	if res.ID != added.ID || res.Behavior != protocol.BehaviorAllow {
		t.Fatalf("resolved %+v", res)
	}
	sess := decode[protocol.Session](t, ui.waitFor(protocol.TypeSessionUpdated))
	if sess.Key != "claude-code:s1" || sess.State != protocol.StateActive {
		t.Fatalf("session %+v", sess)
	}
	if p := s.Snapshot().Approvals; len(p) != 0 {
		t.Fatalf("still pending %+v", p)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(audits) != 1 || audits[0].Decision != "allow" || audits[0].Source != "notch" || audits[0].Summary != "npm test" {
		t.Fatalf("audits %+v", audits)
	}
}

func TestNoDeciderNoWait(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	t0 := time.Now()
	h := hook(t, s.sock, permission("s1", "npm test"))
	env, err := h.next(100 * time.Millisecond)
	if err != nil {
		t.Fatalf("no ack within 100ms: %v", err)
	}
	if env.Type != protocol.TypeHookAck || decode[protocol.HookAck](t, env).Wait {
		t.Fatalf("got %s %s after %v", env.Type, env.Data, time.Since(t0))
	}
	if p := s.Snapshot().Approvals; len(p) != 0 {
		t.Fatalf("pending %+v", p)
	}
}

func TestNoWaitWhenApprovalsOffOrUnsupported(t *testing.T) {
	cfg := config.Default()
	cfg.Approvals.Agents["codex"] = true // codex: IsPermissionEvent true, Approvals None
	cfg.Approvals.Agents["claude-code"] = false
	s := start(t, Options{Config: cfg})
	subscribe(t, s.sock)

	h := hook(t, s.sock, permission("s1", "npm test"))
	if ack := readAck(t, h); ack.Wait {
		t.Fatal("claude-code approvals are off but hook waits")
	}
	ev := permission("s2", "npm test")
	ev.Agent = "codex"
	h2 := hook(t, s.sock, ev)
	if ack := readAck(t, h2); ack.Wait {
		t.Fatal("codex has no approval support but hook waits")
	}
}

func TestPolicyDenyWithoutUI(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	h := hook(t, s.sock, permission("s1", "rm -rf /"))
	if ack := readAck(t, h); !ack.Wait {
		t.Fatal("policy verdict must make the hook wait for the decision")
	}
	d := readDecision(t, h)
	if d.Behavior != protocol.BehaviorDeny || d.Source != "local" || d.Message == "" {
		t.Fatalf("decision %+v", d)
	}
}

func TestPolicyAskStillPrompts(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	ui, _ := subscribe(t, s.sock)
	h := hook(t, s.sock, permission("s1", "git push origin main --force"))
	if ack := readAck(t, h); !ack.Wait || ack.ApprovalID == "" {
		t.Fatalf("ack %+v", ack)
	}
	ui.waitFor(protocol.TypeApprovalAdded)
}

func TestHookDisconnectExpires(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	ui, _ := subscribe(t, s.sock)
	h := hook(t, s.sock, permission("s1", "npm test"))
	ack := readAck(t, h)
	ui.waitFor(protocol.TypeApprovalAdded)
	h.conn.Close()
	res := decode[protocol.ApprovalResolved](t, ui.waitFor(protocol.TypeApprovalResolved))
	if res.ID != ack.ApprovalID || res.Behavior != protocol.BehaviorNone || res.Source != "hook-gone" {
		t.Fatalf("resolved %+v", res)
	}
	if p := s.Snapshot().Approvals; len(p) != 0 {
		t.Fatalf("leaked pending %+v", p)
	}
}

func TestApprovalTimeoutExpires(t *testing.T) {
	cfg := config.Default()
	cfg.Approvals.TimeoutSeconds = 1
	s := start(t, Options{Config: cfg})
	ui, _ := subscribe(t, s.sock)
	h := hook(t, s.sock, permission("s1", "npm test"))
	if ack := readAck(t, h); ack.TimeoutMS != 1000 {
		t.Fatalf("ack %+v", ack)
	}
	if d := readDecision(t, h); d.Behavior != protocol.BehaviorNone {
		t.Fatalf("decision %+v", d)
	}
	if res := decode[protocol.ApprovalResolved](t, ui.waitFor(protocol.TypeApprovalResolved)); res.Behavior != protocol.BehaviorNone || res.Source != "timeout" {
		t.Fatalf("resolved %+v", res)
	}
	if n := decode[protocol.Notice](t, ui.waitFor(protocol.TypeNotice)); n.Kind != "approval-timeout" {
		t.Fatalf("notice %+v", n)
	}
	if p := s.Snapshot().Approvals; len(p) != 0 {
		t.Fatalf("leaked pending %+v", p)
	}
}

func TestDecideValidation(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	ui, _ := subscribe(t, s.sock)
	h := hook(t, s.sock, permission("s1", "npm test"))
	ack := readAck(t, h)
	ui.send(protocol.TypeApprovalDecide, "bad", protocol.ApprovalDecide{ID: ack.ApprovalID, Behavior: protocol.BehaviorNone})
	if env := ui.waitFor(protocol.TypeError); env.ID != "bad" {
		t.Fatalf("error id %q", env.ID)
	}
	ui.send(protocol.TypeApprovalDecide, "unk", protocol.ApprovalDecide{ID: "apr_nope", Behavior: protocol.BehaviorAllow})
	if env := ui.waitFor(protocol.TypeError); env.ID != "unk" {
		t.Fatalf("error id %q", env.ID)
	}
	if err := s.Decide(protocol.ApprovalDecide{ID: ack.ApprovalID, Behavior: "maybe"}); err == nil {
		t.Fatal("host Decide accepted an invalid behavior")
	}
	ui.send(protocol.TypeApprovalDecide, "ok", protocol.ApprovalDecide{ID: ack.ApprovalID, Behavior: protocol.BehaviorDeny, Message: "no"})
	if d := readDecision(t, h); d.Behavior != protocol.BehaviorDeny || d.Message != "no" {
		t.Fatalf("decision %+v", d)
	}
}

func TestSessionDoneNotice(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	ui, _ := subscribe(t, s.sock)
	readAck(t, hook(t, s.sock, claudeEvent("user-prompt-submit", "s1", `{"session_id":"s1","prompt":"go"}`, false)))
	readAck(t, hook(t, s.sock, claudeEvent("stop", "s1", `{"session_id":"s1"}`, false)))
	n := decode[protocol.Notice](t, ui.waitFor(protocol.TypeNotice))
	if n.Kind != "session-done" || n.SessionKey != "claude-code:s1" {
		t.Fatalf("notice %+v", n)
	}
	readAck(t, hook(t, s.sock, claudeEvent("user-prompt-submit", "s1", `{"session_id":"s1","prompt":"again"}`, false)))
	readAck(t, hook(t, s.sock, claudeEvent("stop-failure", "s1", `{"session_id":"s1"}`, false)))
	if n := decode[protocol.Notice](t, ui.waitFor(protocol.TypeNotice)); n.Kind != "session-failed" {
		t.Fatalf("notice %+v", n)
	}
}

func TestMemoryOff(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	c := dial(t, s.sock, protocol.RoleCLI)
	c.send(protocol.TypeCaptureText, "", protocol.CaptureText{AppName: "x", Text: "y"})
	c.send(protocol.TypeMemorySearch, "q1", protocol.MemorySearch{Query: "budget"})
	env := c.waitFor(protocol.TypeError)
	if env.ID != "q1" || !strings.Contains(string(env.Data), "memory is off") {
		t.Fatalf("got %s %s", env.ID, env.Data)
	}
}

// fakeMemory records ingests and answers searches.
type fakeMemory struct {
	mu      sync.Mutex
	ingests []protocol.CaptureText
	onLoops func([]protocol.Loop)
}

func (m *fakeMemory) Ingest(_ context.Context, c protocol.CaptureText) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.ingests = append(m.ingests, c)
	return nil
}
func (m *fakeMemory) Search(_ context.Context, q protocol.MemorySearch) ([]protocol.MemoryHit, error) {
	return []protocol.MemoryHit{{ThreadID: "t1", Snippet: q.Query}}, nil
}
func (m *fakeMemory) Loops(context.Context, string) ([]protocol.Loop, error) {
	return []protocol.Loop{{ID: "loop_1", Title: "Send draft", Status: "open"}}, nil
}
func (m *fakeMemory) SetLoopStatus(_ context.Context, s protocol.LoopSetStatus) error {
	if s.ID == "missing" {
		return errors.New("loop not found")
	}
	m.mu.Lock()
	fn := m.onLoops
	m.mu.Unlock()
	if fn != nil {
		fn([]protocol.Loop{})
	}
	return nil
}
func (m *fakeMemory) Status() protocol.MemoryStatus {
	return protocol.MemoryStatus{Enabled: true, Chunks: 3}
}
func (m *fakeMemory) OnLoopsChanged(fn func([]protocol.Loop)) {
	m.mu.Lock()
	m.onLoops = fn
	m.mu.Unlock()
}
func (m *fakeMemory) Close() error { return nil }

func TestMemoryOn(t *testing.T) {
	mem := &fakeMemory{}
	s := start(t, Options{Config: config.Default(), Memory: mem, Edition: "pro"})
	ui, snap := subscribe(t, s.sock)
	if snap.Edition != "pro" || !snap.Memory.Enabled || snap.Memory.Chunks != 3 || len(snap.Loops) != 1 {
		t.Fatalf("snapshot %+v", snap)
	}
	ui.send(protocol.TypeMemorySearch, "q1", protocol.MemorySearch{Query: "budget"})
	env := ui.waitFor(protocol.TypeMemoryResults)
	if res := decode[protocol.MemoryResults](t, env); env.ID != "q1" || len(res.Hits) != 1 || res.Hits[0].Snippet != "budget" {
		t.Fatalf("results %s %s", env.ID, env.Data)
	}
	ui.send(protocol.TypeLoopSetStatus, "l1", protocol.LoopSetStatus{ID: "loop_1", Status: "resolved"})
	if loops := decode[[]protocol.Loop](t, ui.waitFor(protocol.TypeLoopsUpdated)); len(loops) != 0 {
		t.Fatalf("loops %+v", loops)
	}
	if ack := ui.waitFor(protocol.TypeLoopSetStatus); ack.ID != "l1" {
		t.Fatalf("ack id %q", ack.ID)
	}
	ui.send(protocol.TypeLoopSetStatus, "l2", protocol.LoopSetStatus{ID: "missing", Status: "resolved"})
	if e := ui.waitFor(protocol.TypeError); e.ID != "l2" || decode[protocol.ErrorMsg](t, e).Message != "loop not found" {
		t.Fatalf("error reply %s %s", e.ID, e.Data)
	}
	ui.send(protocol.TypeCaptureText, "", protocol.CaptureText{AppName: "Slack", Text: "hello"})
	ui.send(protocol.TypePing, "p", nil) // capture is handled in order before the ping
	ui.waitFor(protocol.TypePong)
	mem.mu.Lock()
	defer mem.mu.Unlock()
	if len(mem.ingests) != 1 || mem.ingests[0].Text != "hello" {
		t.Fatalf("ingests %+v", mem.ingests)
	}
}

type auditFunc func(ext.AuditEvent)

func (f auditFunc) Record(e ext.AuditEvent) { f(e) }

type fakeProvider struct{}

func (fakeProvider) Name() string { return "fake" }
func (fakeProvider) Evaluate(tool, summary string) (policy.Verdict, bool) {
	if tool == "Bash" && summary == "rm -rf /" {
		return policy.Verdict{Action: "allow", Reason: "trusted sandbox", Source: "fake"}, true
	}
	return policy.Verdict{}, false
}

type fakeExt struct {
	started chan ext.Host
}

func (*fakeExt) Name() string { return "fake" }
func (f *fakeExt) Start(_ context.Context, h ext.Host) error {
	h.AddPolicy(fakeProvider{})
	h.RegisterDecider("fake")
	h.Subscribe(func(env protocol.Envelope) {
		if env.Type != protocol.TypeApprovalAdded {
			return
		}
		var a protocol.Approval
		_ = env.Decode(&a)
		if err := h.Decide(protocol.ApprovalDecide{ID: a.ID, Behavior: protocol.BehaviorAllow, Source: "fake"}); err != nil {
			h.Logf("decide: %v", err)
		}
	})
	f.started <- h
	return nil
}

func (*fakeExt) HandleRequest(_ context.Context, kind string, data json.RawMessage) (any, error) {
	switch kind {
	case "ping":
		return map[string]any{"pong": true, "echo": data}, nil
	}
	return nil, errors.New("unknown kind " + kind)
}

func TestExtensionHost(t *testing.T) {
	fe := &fakeExt{started: make(chan ext.Host, 1)}
	s := start(t, Options{Config: config.Default(), Extensions: []ext.Extension{fe}})
	var h ext.Host
	select {
	case h = <-fe.started:
	case <-time.After(2 * time.Second):
		t.Fatal("extension not started")
	}
	if h.Edition() != "free" || h.Memory() != nil || !h.Config().ApprovalsOn("claude-code") {
		t.Fatal("host accessors")
	}

	// The extension policy is evaluated before the local deny rule.
	hc := hook(t, s.sock, permission("s1", "rm -rf /"))
	readAck(t, hc)
	if d := readDecision(t, hc); d.Behavior != protocol.BehaviorAllow || d.Source != "fake" {
		t.Fatalf("decision %+v", d)
	}

	// No UI, but the registered decider makes the hook wait; the extension
	// answers through Host.Decide.
	hc2 := hook(t, s.sock, permission("s2", "npm test"))
	if ack := readAck(t, hc2); !ack.Wait || ack.ApprovalID == "" {
		t.Fatalf("ack %+v", ack)
	}
	if d := readDecision(t, hc2); d.Behavior != protocol.BehaviorAllow || d.Source != "fake" {
		t.Fatalf("decision %+v", d)
	}
}

func TestExtRequestRouting(t *testing.T) {
	fe := &fakeExt{started: make(chan ext.Host, 1)}
	s := start(t, Options{Config: config.Default(), Extensions: []ext.Extension{fe}})
	ui := dial(t, s.sock, protocol.RoleUI)
	ui.send(protocol.TypeExtRequest, "r1", protocol.ExtMessage{Ext: "fake", Kind: "ping", Data: json.RawMessage(`{"n":1}`)})
	env := ui.waitFor(protocol.TypeExtRequest)
	if env.ID != "r1" {
		t.Fatalf("reply id %q", env.ID)
	}
	msg := decode[protocol.ExtMessage](t, env)
	if msg.Ext != "fake" || msg.Kind != "ping" || string(msg.Data) != `{"echo":{"n":1},"pong":true}` {
		t.Fatalf("reply %+v data %s", msg, msg.Data)
	}
	ui.send(protocol.TypeExtRequest, "r2", protocol.ExtMessage{Ext: "nope", Kind: "ping"})
	if env := ui.waitFor(protocol.TypeError); env.ID != "r2" {
		t.Fatalf("error id %q", env.ID)
	}
	ui.send(protocol.TypeExtRequest, "r3", protocol.ExtMessage{Ext: "fake", Kind: "boom"})
	if env := ui.waitFor(protocol.TypeError); env.ID != "r3" {
		t.Fatalf("error id %q", env.ID)
	}
}

func TestEmitEvent(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	ui, _ := subscribe(t, s.sock)
	s.EmitEvent("fake", "hello", map[string]int{"n": 2})
	msg := decode[protocol.ExtMessage](t, ui.waitFor(protocol.TypeExtEvent))
	if msg.Ext != "fake" || msg.Kind != "hello" || string(msg.Data) != `{"n":2}` {
		t.Fatalf("event %+v", msg)
	}
}

func TestStaleSocketReplaced(t *testing.T) {
	sock := filepath.Join(shortDir(t), "n.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	ln.(*net.UnixListener).SetUnlinkOnClose(false)
	ln.Close()
	if _, err := os.Stat(sock); err != nil {
		t.Fatalf("stale socket missing: %v", err)
	}
	start(t, Options{Socket: sock, Config: config.Default()})

	second, err := New(Options{Socket: sock, Config: config.Default()})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	err = second.Serve(ctx)
	if err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("second Serve: %v", err)
	}
}

func TestRefusesNonSocketPath(t *testing.T) {
	path := filepath.Join(shortDir(t), "n.sock")
	if err := os.WriteFile(path, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := New(Options{Socket: path, Config: config.Default()})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Serve(context.Background()); err == nil {
		t.Fatal("Serve replaced a regular file")
	}
	if b, _ := os.ReadFile(path); string(b) != "keep me" {
		t.Fatal("regular file was clobbered")
	}
}

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *fakeClock) add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func TestUpsertSweepAndUsage(t *testing.T) {
	clk := &fakeClock{t: time.Date(2026, 10, 23, 10, 0, 0, 0, time.UTC)}
	s := start(t, Options{Config: config.Default(), Now: clk.now})
	ui, _ := subscribe(t, s.sock)

	s.UpsertSessions([]protocol.Session{{Key: "codex:x", Agent: "codex", SessionID: "x", State: protocol.StateExited}})
	if sess := decode[protocol.Session](t, ui.waitFor(protocol.TypeSessionUpdated)); sess.Key != "codex:x" {
		t.Fatalf("session %+v", sess)
	}
	clk.add(11 * time.Minute)
	s.Sweep()
	if rm := decode[protocol.SessionRemoved](t, ui.waitFor(protocol.TypeSessionRemoved)); rm.Key != "codex:x" {
		t.Fatalf("removed %+v", rm)
	}

	u := protocol.Usage{Codex: &protocol.Limits{FiveHour: &protocol.Window{UsedPercent: 8}}}
	s.SetUsage(u)
	if got := decode[protocol.Usage](t, ui.waitFor(protocol.TypeUsageUpdated)); got.Codex == nil || got.Codex.FiveHour.UsedPercent != 8 {
		t.Fatalf("usage %+v", got)
	}
	if snap := s.Snapshot(); snap.Usage.Codex == nil || len(snap.Sessions) != 0 {
		t.Fatalf("snapshot %+v", snap)
	}
}

func TestSlowSubscriberDisconnected(t *testing.T) {
	s := start(t, Options{Config: config.Default()})
	slow, _ := subscribe(t, s.sock) // never reads again
	big := protocol.Usage{Claude: &protocol.Limits{Extra: map[string]protocol.Window{}}}
	for i := 0; i < 200; i++ {
		big.Claude.Extra[fmt.Sprintf("window_%03d", i)] = protocol.Window{UsedPercent: float64(i)}
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 2000; i++ {
			s.SetUsage(big)
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("SetUsage blocked on a slow subscriber")
	}
	// The slow subscriber was dropped: reading drains what was buffered, then EOF.
	slow.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	n := 0
	for {
		_, err := slow.r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("slow subscriber after %d messages: %v", n, err)
		}
		n++
	}
	if n >= 2000 {
		t.Fatalf("slow subscriber got all %d messages; expected a disconnect", n)
	}
	// The server is still healthy for everyone else.
	fresh, snap := subscribe(t, s.sock)
	if snap.Usage.Claude == nil {
		t.Fatal("usage missing from snapshot")
	}
	fresh.send(protocol.TypePing, "p", nil)
	fresh.waitFor(protocol.TypePong)
}

// withGrace shortens the no-decider grace period for one test.
func withGrace(t *testing.T, d time.Duration) {
	t.Helper()
	old := noDeciderGrace
	noDeciderGrace = d
	t.Cleanup(func() { noDeciderGrace = old })
}

func TestLastDeciderGoneExpires(t *testing.T) {
	withGrace(t, 50*time.Millisecond)
	var mu sync.Mutex
	var audits []ext.AuditEvent
	s := start(t, Options{Config: config.Default()})
	s.AddAuditor(auditFunc(func(e ext.AuditEvent) { mu.Lock(); audits = append(audits, e); mu.Unlock() }))
	ui, _ := subscribe(t, s.sock)
	h := hook(t, s.sock, permission("s1", "npm test"))
	readAck(t, h)
	ui.waitFor(protocol.TypeApprovalAdded)
	ui.conn.Close()
	env, err := h.next(time.Second)
	if err != nil || env.Type != protocol.TypeHookDecision {
		t.Fatalf("got %v %v", env.Type, err)
	}
	if d := decode[protocol.HookDecision](t, env); d.Behavior != protocol.BehaviorNone || d.Source != "no-decider" {
		t.Fatalf("decision %+v", d)
	}
	deadline := time.Now().Add(time.Second)
	for {
		mu.Lock()
		n := len(audits)
		mu.Unlock()
		if n == 1 || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(audits) != 1 || audits[0].Source != "no-decider" || audits[0].Decision != protocol.BehaviorNone {
		t.Fatalf("audits %+v", audits)
	}
}

func TestDeciderReconnectWithinGrace(t *testing.T) {
	withGrace(t, 2*time.Second)
	s := start(t, Options{Config: config.Default()})
	ui, _ := subscribe(t, s.sock)
	h := hook(t, s.sock, permission("s1", "npm test"))
	ack := readAck(t, h)
	ui.waitFor(protocol.TypeApprovalAdded)
	ui.conn.Close() // the Mac app restarts
	time.Sleep(100 * time.Millisecond)

	ui2, snap := subscribe(t, s.sock)
	if len(snap.Approvals) != 1 || snap.Approvals[0].ID != ack.ApprovalID {
		t.Fatalf("snapshot approvals %+v", snap.Approvals)
	}
	ui2.send(protocol.TypeApprovalDecide, "d", protocol.ApprovalDecide{ID: ack.ApprovalID, Behavior: protocol.BehaviorAllow})
	if d := readDecision(t, h); d.Behavior != protocol.BehaviorAllow {
		t.Fatalf("decision %+v", d)
	}
	// The cancelled grace timer must not expire later approvals.
	h2 := hook(t, s.sock, permission("s2", "npm run build"))
	ack2 := readAck(t, h2)
	if !ack2.Wait {
		t.Fatal("hook did not wait with a UI connected")
	}
	if _, err := h2.next(2500 * time.Millisecond); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("approval resolved without an answer: %v", err)
	}
}

// A permission event whose own payload names no tool (unreadable, truncated or
// empty) must never reach policy or a human: a catch-all allow rule would
// otherwise auto-allow it, and the session's earlier tool must not be borrowed.
func TestPermissionWithoutToolNeverWaits(t *testing.T) {
	cfg := config.Default()
	cfg.Policy.Rules = append([]config.Rule{{Tool: "*", Pattern: "*", Action: "allow"}}, cfg.Policy.Rules...)
	s := start(t, Options{Config: cfg})
	ui, _ := subscribe(t, s.sock)

	// Seed the session with an earlier tool.
	pre := claudeEvent("pre-tool-use", "s1",
		`{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Bash","tool_input":{"command":"ls"}}`, false)
	readAck(t, hook(t, s.sock, pre))

	for i, payload := range []string{"", `{"session_id":"s1","cwd":"/tmp/proj"}`} {
		ev := claudeEvent("permission-request", "s1", payload, true)
		if payload == "" {
			ev.Payload = nil
		}
		h := hook(t, s.sock, ev)
		if ack := readAck(t, h); ack.Wait {
			t.Fatalf("case %d: hook waits on a tool-less permission event: %+v", i, ack)
		}
		if env, err := h.next(150 * time.Millisecond); err == nil {
			t.Fatalf("case %d: unexpected %s after no-wait ack", i, env.Type)
		}
	}
	for {
		env, err := ui.next(150 * time.Millisecond)
		if err != nil {
			break
		}
		if env.Type == protocol.TypeApprovalAdded {
			t.Fatalf("approval opened: %s", env.Data)
		}
	}
	if p := s.Snapshot().Approvals; len(p) != 0 {
		t.Fatalf("pending %+v", p)
	}
}
