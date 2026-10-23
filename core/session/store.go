// Package session tracks the live state of every coding-agent session from
// hook events.
package session

import (
	"errors"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/platynotch/platynotch/core/agents"
	"github.com/platynotch/platynotch/core/protocol"
)

const (
	staleAfter   = 30 * time.Minute
	removeAfter  = 10 * time.Minute
	maxTitleRune = 80
)

// Key identifies a session: agent+":"+sessionID, or agent+":pid"+pid when the
// agent gave no session id.
func Key(agent, sessionID string, pid int) string {
	if sessionID != "" {
		return agent + ":" + sessionID
	}
	return agent + ":pid" + strconv.Itoa(pid)
}

type meta struct {
	hookFed   bool
	blockID   string // tool_use_id of the blocking permission request
	blockTool string
	exitedAt  time.Time
}

type Store struct {
	now   func() time.Time
	alive func(pid int) bool
	mu    sync.Mutex
	s     map[string]*protocol.Session
	meta  map[string]*meta
}

// NewStore builds a store. A nil alive checks the process with signal 0.
func NewStore(now func() time.Time, alive func(pid int) bool) *Store {
	if now == nil {
		now = time.Now
	}
	if alive == nil {
		alive = pidAlive
	}
	return &Store{now: now, alive: alive, s: map[string]*protocol.Session{}, meta: map[string]*meta{}}
}

func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = strings.TrimSpace(s[:i])
	}
	if r := []rune(s); len(r) > maxTitleRune {
		s = string(r[:maxTitleRune])
	}
	return s
}

func clearsBlock(event string, c agents.Common, m *meta) bool {
	switch event {
	case "user-prompt-submit", "stop", "stop-failure", "session-end":
		return true
	case "post-tool-use", "post-tool-use-failure":
		if m.blockID != "" {
			return c.ToolUseID == m.blockID
		}
		return c.Tool != "" && c.Tool == m.blockTool
	}
	return false
}

// Apply folds one hook event into the store. The bool reports whether the
// session's state or fields changed (UpdatedAt alone does not count).
func (s *Store) Apply(ev protocol.HookEvent, a agents.Adapter) (protocol.Session, bool) {
	c := a.ParseCommon(ev.Event, ev.Payload)
	key := Key(ev.Agent, c.SessionID, ev.PID)
	now := s.now()

	s.mu.Lock()
	defer s.mu.Unlock()

	sess, exists := s.s[key]
	m := s.meta[key]
	if exists && ev.PID > 0 && sess.PID > 0 && ev.PID != sess.PID && s.alive(sess.PID) {
		return *sess, false // nested process while the pinned pid lives
	}
	if !exists {
		sess = &protocol.Session{Key: key, Agent: ev.Agent, SessionID: c.SessionID, StartedAt: now, State: protocol.StateIdle}
		m = &meta{hookFed: true}
		s.s[key], s.meta[key] = sess, m
	}
	m.hookFed = true
	before := *sess

	sess.AgentName = a.Name()
	if ev.PID > 0 {
		sess.PID = ev.PID // pins the first pid; re-pins only after the old one died
	}
	if cwd := firstNonEmpty(c.CWD, ev.CWD); cwd != "" {
		sess.CWD = cwd
		sess.Project = filepath.Base(cwd)
	}
	if ev.TTY != "" {
		sess.TTY = ev.TTY
	}
	if ev.TermProgram != "" {
		sess.TermProgram = ev.TermProgram
	}
	if ev.Event == "user-prompt-submit" {
		if t := firstLine(c.Prompt); t != "" {
			sess.Title = t
		}
	}
	if c.Message != "" {
		sess.Message = c.Message
	}
	switch ev.Event {
	case "subagent-start":
		sess.Subagents++
	case "subagent-stop":
		if sess.Subagents > 0 {
			sess.Subagents--
		}
	}

	if st, ok := a.DeriveState(ev.Event, ev.Payload); ok {
		if sess.State == protocol.StateBlocked && st != protocol.StateBlocked && !clearsBlock(ev.Event, c, m) {
			st = protocol.StateBlocked
		}
		if st == protocol.StateBlocked && (before.State != protocol.StateBlocked || a.IsPermissionEvent(ev.Event)) {
			m.blockID, m.blockTool = c.ToolUseID, c.Tool
		}
		if st != protocol.StateBlocked {
			m.blockID, m.blockTool = "", ""
		}
		if st == protocol.StateExited && sess.State != protocol.StateExited {
			m.exitedAt = now
		} else if st != protocol.StateExited {
			m.exitedAt = time.Time{}
		}
		sess.State = st
	}
	// While blocked, Tool stays the blocking tool, not parallel tool traffic.
	if c.Tool != "" && (sess.State != protocol.StateBlocked || before.State != protocol.StateBlocked || a.IsPermissionEvent(ev.Event)) {
		sess.Tool = c.Tool
	}
	sess.UpdatedAt = now

	b := before
	b.UpdatedAt = sess.UpdatedAt
	return *sess, b != *sess || !exists
}

func firstNonEmpty(v ...string) string {
	for _, x := range v {
		if x != "" {
			return x
		}
	}
	return ""
}

// Resolve marks a blocked session active again after its approval was answered.
func (s *Store) Resolve(key string) (protocol.Session, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.s[key]
	if !ok || sess.State != protocol.StateBlocked {
		return protocol.Session{}, false
	}
	sess.State = protocol.StateActive
	sess.UpdatedAt = s.now()
	if m := s.meta[key]; m != nil {
		m.blockID, m.blockTool = "", ""
	}
	return *sess, true
}

// Upsert adds a discovered session; an existing session is never replaced if
// hooks have fed it.
func (s *Store) Upsert(in protocol.Session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if m := s.meta[in.Key]; m != nil && m.hookFed {
		return
	}
	now := s.now()
	if in.State == "" {
		in.State = protocol.StateIdle
	}
	if in.StartedAt.IsZero() {
		in.StartedAt = now
	}
	if in.UpdatedAt.IsZero() {
		in.UpdatedAt = now
	}
	cp := in
	s.s[in.Key] = &cp
	m := &meta{}
	if in.State == protocol.StateExited {
		m.exitedAt = now
	}
	s.meta[in.Key] = m
}

// Sweep exits sessions idle for 30 min whose process is dead, and removes
// exited sessions 10 min after they exited.
func (s *Store) Sweep(alive func(pid int) bool) (changed, removed []protocol.Session) {
	if alive == nil {
		alive = s.alive
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for key, sess := range s.s {
		m := s.meta[key]
		if sess.State == protocol.StateExited {
			if !m.exitedAt.IsZero() && now.Sub(m.exitedAt) >= removeAfter {
				removed = append(removed, *sess)
				delete(s.s, key)
				delete(s.meta, key)
			}
			continue
		}
		if now.Sub(sess.UpdatedAt) >= staleAfter && !(sess.PID > 0 && alive(sess.PID)) {
			sess.State = protocol.StateExited
			m.exitedAt = now
			m.blockID, m.blockTool = "", ""
			changed = append(changed, *sess)
		}
	}
	return changed, removed
}

// List returns all sessions, newest UpdatedAt first.
func (s *Store) List() []protocol.Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]protocol.Session, 0, len(s.s))
	for _, v := range s.s {
		out = append(out, *v)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].UpdatedAt.Equal(out[j].UpdatedAt) {
			return out[i].UpdatedAt.After(out[j].UpdatedAt)
		}
		return out[i].Key < out[j].Key
	})
	return out
}
