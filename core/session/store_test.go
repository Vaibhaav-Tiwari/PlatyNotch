package session

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// fakeAdapter derives state from the kebab-case event name and reads a flat
// JSON payload.
type fakeAdapter struct{}

func (fakeAdapter) ID() string                                          { return "fake" }
func (fakeAdapter) Name() string                                        { return "Fake Agent" }
func (fakeAdapter) Detect() bool                                        { return true }
func (fakeAdapter) ConfigPath() string                                  { return "" }
func (fakeAdapter) InstallHooks(string) (bool, error)                   { return false, nil }
func (fakeAdapter) UninstallHooks() (bool, error)                       { return false, nil }
func (fakeAdapter) HooksInstalled() (bool, error)                       { return false, nil }
func (fakeAdapter) Approvals() agents.ApprovalSupport                   { return agents.ApprovalsNone }
func (fakeAdapter) IsPermissionEvent(e string) bool                     { return e == "permission-request" }
func (fakeAdapter) FormatDecision(string, protocol.HookDecision) []byte { return nil }
func (fakeAdapter) DeriveState(event string, _ []byte) (protocol.State, bool) {
	switch event {
	case "permission-request":
		return protocol.StateBlocked, true
	case "pre-tool-use", "post-tool-use", "post-tool-use-failure", "user-prompt-submit", "session-start":
		return protocol.StateActive, true
	case "stop":
		return protocol.StateIdle, true
	case "stop-failure":
		return protocol.StateWaitingInput, true
	case "session-end":
		return protocol.StateExited, true
	}
	return "", false
}
func (fakeAdapter) ParseCommon(_ string, payload []byte) agents.Common {
	var p struct {
		SessionID string `json:"sid"`
		CWD       string `json:"cwd"`
		Tool      string `json:"tool"`
		ToolUseID string `json:"tuid"`
		Prompt    string `json:"prompt"`
		Message   string `json:"message"`
	}
	_ = json.Unmarshal(payload, &p)
	return agents.Common{SessionID: p.SessionID, CWD: p.CWD, Tool: p.Tool, ToolUseID: p.ToolUseID, Prompt: p.Prompt, Message: p.Message}
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func ev(event string, pid int, payload string) protocol.HookEvent {
	return protocol.HookEvent{Agent: "fake", Event: event, PID: pid, Payload: json.RawMessage(payload)}
}

func newTestStore(alive func(int) bool) (*Store, *clock) {
	c := &clock{t: time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)}
	return NewStore(c.now, alive), c
}

func TestKey(t *testing.T) {
	if got := Key("a", "s1", 5); got != "a:s1" {
		t.Fatal(got)
	}
	if got := Key("a", "", 5); got != "a:pid5" {
		t.Fatal(got)
	}
}

func TestBasicFields(t *testing.T) {
	s, c := newTestStore(func(int) bool { return true })
	e := ev("user-prompt-submit", 100, `{"sid":"s1","cwd":"/work/proj","prompt":"first line\nsecond"}`)
	e.TTY, e.TermProgram = "ttys004", "iTerm.app"
	sess, changed := s.Apply(e, fakeAdapter{})
	if !changed || sess.Key != "fake:s1" || sess.AgentName != "Fake Agent" || sess.Project != "proj" ||
		sess.Title != "first line" || sess.State != protocol.StateActive || sess.TTY != "ttys004" ||
		sess.TermProgram != "iTerm.app" || sess.PID != 100 || !sess.StartedAt.Equal(c.t) {
		t.Fatalf("%+v", sess)
	}
	c.t = c.t.Add(time.Minute)
	sess, _ = s.Apply(ev("pre-tool-use", 100, `{"sid":"s1","tool":"Bash"}`), fakeAdapter{})
	if sess.TermProgram != "iTerm.app" || sess.Tool != "Bash" || sess.Title != "first line" || !sess.UpdatedAt.Equal(c.t) {
		t.Fatalf("%+v", sess)
	}
}

func TestTitleTruncated(t *testing.T) {
	s, _ := newTestStore(nil)
	long := ""
	for i := 0; i < 100; i++ {
		long += "é"
	}
	sess, _ := s.Apply(ev("user-prompt-submit", 1, `{"sid":"s","prompt":"`+long+`"}`), fakeAdapter{})
	if n := len([]rune(sess.Title)); n != 80 {
		t.Fatal(n)
	}
}

func TestSubagents(t *testing.T) {
	s, _ := newTestStore(nil)
	a := fakeAdapter{}
	s.Apply(ev("subagent-start", 1, `{"sid":"s"}`), a)
	s.Apply(ev("subagent-start", 1, `{"sid":"s"}`), a)
	sess, _ := s.Apply(ev("subagent-stop", 1, `{"sid":"s"}`), a)
	if sess.Subagents != 1 {
		t.Fatal(sess.Subagents)
	}
	s.Apply(ev("subagent-stop", 1, `{"sid":"s"}`), a)
	sess, _ = s.Apply(ev("subagent-stop", 1, `{"sid":"s"}`), a)
	if sess.Subagents != 0 {
		t.Fatal(sess.Subagents)
	}
}

func TestBlockedSurvivesParallelToolTraffic(t *testing.T) {
	s, _ := newTestStore(func(int) bool { return true })
	a := fakeAdapter{}
	sess, _ := s.Apply(ev("permission-request", 1, `{"sid":"s","tool":"Bash","tuid":"t1"}`), a)
	if sess.State != protocol.StateBlocked {
		t.Fatal(sess.State)
	}
	sess, _ = s.Apply(ev("pre-tool-use", 1, `{"sid":"s","tool":"Read","tuid":"t2"}`), a)
	if sess.State != protocol.StateBlocked || sess.Tool != "Bash" {
		t.Fatalf("%+v", sess)
	}
	sess, _ = s.Apply(ev("post-tool-use", 1, `{"sid":"s","tool":"Read","tuid":"t2"}`), a)
	if sess.State != protocol.StateBlocked {
		t.Fatal("cleared by wrong tool use id")
	}
	sess, _ = s.Apply(ev("post-tool-use", 1, `{"sid":"s","tool":"Bash","tuid":"t1"}`), a)
	if sess.State != protocol.StateActive {
		t.Fatal(sess.State)
	}
}

func TestBlockedClearedByOthers(t *testing.T) {
	for _, event := range []string{"user-prompt-submit", "stop", "stop-failure", "session-end"} {
		s, _ := newTestStore(func(int) bool { return true })
		a := fakeAdapter{}
		s.Apply(ev("permission-request", 1, `{"sid":"s","tool":"Bash","tuid":"t1"}`), a)
		sess, _ := s.Apply(ev(event, 1, `{"sid":"s"}`), a)
		if sess.State == protocol.StateBlocked {
			t.Fatalf("%s did not clear blocked", event)
		}
	}
}

func TestBlockedByToolNameWhenNoID(t *testing.T) {
	s, _ := newTestStore(nil)
	a := fakeAdapter{}
	s.Apply(ev("permission-request", 1, `{"sid":"s","tool":"Bash"}`), a)
	sess, _ := s.Apply(ev("post-tool-use", 1, `{"sid":"s","tool":"Read"}`), a)
	if sess.State != protocol.StateBlocked {
		t.Fatal("cleared by other tool")
	}
	sess, _ = s.Apply(ev("post-tool-use", 1, `{"sid":"s","tool":"Bash"}`), a)
	if sess.State != protocol.StateActive {
		t.Fatal(sess.State)
	}
}

func TestResolve(t *testing.T) {
	s, _ := newTestStore(nil)
	s.Apply(ev("permission-request", 1, `{"sid":"s","tool":"Bash","tuid":"t1"}`), fakeAdapter{})
	sess, ok := s.Resolve("fake:s")
	if !ok || sess.State != protocol.StateActive {
		t.Fatalf("%+v %v", sess, ok)
	}
	if _, ok := s.Resolve("fake:s"); ok {
		t.Fatal("second resolve should be no-op")
	}
	if _, ok := s.Resolve("nope"); ok {
		t.Fatal("unknown")
	}
}

func TestNestedProcessIgnored(t *testing.T) {
	s, _ := newTestStore(func(pid int) bool { return pid == 100 })
	a := fakeAdapter{}
	s.Apply(ev("pre-tool-use", 100, `{"sid":"s"}`), a)
	sess, changed := s.Apply(ev("stop", 200, `{"sid":"s"}`), a)
	if changed || sess.State != protocol.StateActive || sess.PID != 100 {
		t.Fatalf("%+v %v", sess, changed)
	}
	sess, _ = s.Apply(ev("stop", 100, `{"sid":"s"}`), a)
	if sess.State != protocol.StateIdle {
		t.Fatal(sess.State)
	}
}

func TestRepinAfterDeath(t *testing.T) {
	s, _ := newTestStore(func(pid int) bool { return false })
	a := fakeAdapter{}
	s.Apply(ev("pre-tool-use", 100, `{"sid":"s"}`), a)
	sess, _ := s.Apply(ev("stop", 200, `{"sid":"s"}`), a)
	if sess.State != protocol.StateIdle || sess.PID != 200 {
		t.Fatalf("%+v", sess)
	}
}

func TestSweep(t *testing.T) {
	s, c := newTestStore(nil)
	s.Apply(ev("stop", 100, `{"sid":"s"}`), fakeAdapter{})
	dead := func(int) bool { return false }
	c.t = c.t.Add(29 * time.Minute)
	if ch, rm := s.Sweep(dead); len(ch)+len(rm) != 0 {
		t.Fatal("too early")
	}
	c.t = c.t.Add(2 * time.Minute)
	if ch, rm := s.Sweep(func(int) bool { return true }); len(ch)+len(rm) != 0 {
		t.Fatal("alive pid must stay")
	}
	ch, rm := s.Sweep(dead)
	if len(ch) != 1 || ch[0].State != protocol.StateExited || len(rm) != 0 {
		t.Fatalf("%v %v", ch, rm)
	}
	c.t = c.t.Add(9 * time.Minute)
	if ch, rm := s.Sweep(dead); len(ch)+len(rm) != 0 {
		t.Fatal("too early to remove")
	}
	c.t = c.t.Add(2 * time.Minute)
	ch, rm = s.Sweep(dead)
	if len(rm) != 1 || len(ch) != 0 || len(s.List()) != 0 {
		t.Fatalf("%v %v", ch, rm)
	}
}

func TestUpsertNeverOverridesHookFed(t *testing.T) {
	s, _ := newTestStore(nil)
	s.Apply(ev("stop", 1, `{"sid":"s"}`), fakeAdapter{})
	s.Upsert(protocol.Session{Key: "fake:s", State: protocol.StateActive, Title: "disc"})
	if got := s.List()[0]; got.State != protocol.StateIdle || got.Title != "" {
		t.Fatalf("%+v", got)
	}
	s.Upsert(protocol.Session{Key: "fake:d", Agent: "fake", State: protocol.StateIdle})
	if len(s.List()) != 2 {
		t.Fatal("discovery session missing")
	}
}

func TestListNewestFirst(t *testing.T) {
	s, c := newTestStore(nil)
	s.Apply(ev("stop", 1, `{"sid":"a"}`), fakeAdapter{})
	c.t = c.t.Add(time.Second)
	s.Apply(ev("stop", 2, `{"sid":"b"}`), fakeAdapter{})
	l := s.List()
	if l[0].SessionID != "b" || l[1].SessionID != "a" {
		t.Fatalf("%+v", l)
	}
}

func TestGet(t *testing.T) {
	c := &clock{t: time.Unix(1000, 0)}
	s := NewStore(c.now, func(int) bool { return false })
	if _, ok := s.Get("fake:s1"); ok {
		t.Fatal("Get on empty store reported a session")
	}
	s.Apply(ev("user-prompt-submit", 0, `{"sid":"s1"}`), fakeAdapter{})
	got, ok := s.Get("fake:s1")
	if !ok || got.State != protocol.StateActive || got.Key != "fake:s1" {
		t.Fatalf("Get = %+v, %v", got, ok)
	}
}
