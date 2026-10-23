// Package hookcli implements `notch hook <agent> <event>`: it forwards an
// agent's hook event to the running core and, for permission events, waits for
// the user's decision. It must never break or block an agent: every failure
// path returns 0 and prints nothing.
package hookcli

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/platynotch/platynotch/core/agents"
	"github.com/platynotch/platynotch/core/paths"
	"github.com/platynotch/platynotch/core/protocol"
	"github.com/platynotch/platynotch/core/wire"
)

const (
	// maxStdin leaves room for the envelope around the payload so one hook
	// event always fits a single wire line.
	maxStdin    = wire.MaxLine - 64<<10
	dialTimeout = 300 * time.Millisecond
	sendBudget  = time.Second
	ackBudget   = 2 * time.Second
	graceAfter  = 2 * time.Second
	clientName  = "notch-hook/0.1.0"
)

// Run forwards one hook event. It always returns 0.
func Run(agent, event string, stdin io.Reader, stdout io.Writer, env func(string) string) int {
	defer func() { _ = recover() }()
	if env == nil {
		env = os.Getenv
	}

	raw, _ := io.ReadAll(io.LimitReader(stdin, maxStdin+1))
	_, _ = io.Copy(io.Discard, stdin) // drop any excess so the agent's pipe never blocks
	tooBig := len(raw) > maxStdin

	adapter, ok := agents.Get(agent)
	if !ok {
		return 0
	}

	sock := env("PLATYNOTCH_SOCKET")
	if sock == "" {
		sock = paths.Socket()
	}
	conn, err := net.DialTimeout("unix", sock, dialTimeout)
	if err != nil {
		return 0
	}
	defer conn.Close()

	// An oversize payload is never forwarded: the event still updates
	// session state, but no decision is requested for a call nobody can see.
	want := !tooBig && adapter.IsPermissionEvent(event) && adapter.Approvals() != agents.ApprovalsNone

	ev := protocol.HookEvent{
		Agent:        agent,
		Event:        event,
		PPID:         os.Getppid(),
		TermProgram:  env("TERM_PROGRAM"),
		WantDecision: want,
		At:           time.Now().UTC(),
	}
	if !tooBig && json.Valid(raw) {
		ev.Payload = json.RawMessage(raw)
	}
	if wd, err := os.Getwd(); err == nil {
		ev.CWD = wd
	}
	if needsProcInfo(event) {
		fillProcInfo(&ev, env("CLAUDE_PID"))
	}

	// JSON escaping can grow a payload past one wire line; if so, drop it
	// (and the decision request) rather than send a line the core rejects.
	if b, err := json.Marshal(ev); err != nil || len(b) > maxStdin {
		ev.Payload, ev.WantDecision, want = nil, false, false
	}

	_ = conn.SetDeadline(time.Now().Add(sendBudget))
	w := wire.NewWriter(conn)
	if w.Send(protocol.TypeHello, "", protocol.Hello{Role: protocol.RoleHook, Client: clientName, Version: protocol.Version}) != nil {
		return 0
	}
	const id = "1"
	if w.Send(protocol.TypeHookEvent, id, ev) != nil {
		return 0
	}
	if !want {
		return 0
	}

	r := wire.NewReader(conn)
	_ = conn.SetReadDeadline(time.Now().Add(ackBudget))
	ack, err := r.Read()
	if err != nil || ack.Type != protocol.TypeHookAck || ack.ID != id {
		return 0
	}
	var a protocol.HookAck
	if ack.Decode(&a) != nil || !a.Wait {
		return 0
	}
	wait := time.Duration(a.TimeoutMS)*time.Millisecond + graceAfter
	_ = conn.SetReadDeadline(time.Now().Add(wait))
	for {
		msg, err := r.Read()
		if err != nil {
			return 0
		}
		if msg.Type != protocol.TypeHookDecision || msg.ID != id {
			continue
		}
		var d protocol.HookDecision
		if msg.Decode(&d) != nil {
			return 0
		}
		if out := adapter.FormatDecision(event, d); out != nil {
			_, _ = stdout.Write(append(out, '\n'))
		}
		return 0
	}
}

func needsProcInfo(event string) bool {
	switch event {
	case "session-start", "user-prompt-submit", "permission-request", "notification":
		return true
	}
	return false
}

// fillProcInfo sets PID and TTY. Failures leave the fields empty.
func fillProcInfo(ev *protocol.HookEvent, claudePID string) {
	pid := agentPID(claudePID, os.Getppid(), procName, parentOf)
	ev.PID = pid
	if pid > 0 {
		ev.TTY = ttyOf(pid)
	}
}

// agentPID picks the agent's PID: CLAUDE_PID when set, else our parent. Hook
// runners use `sh -c`, which execs the command, so the parent is normally the
// agent itself; when it is still a shell (a compound hook command), the agent
// is one level further up.
func agentPID(claudePID string, ppid int, name func(int) string, parent func(int) int) int {
	if n, err := strconv.Atoi(claudePID); err == nil && n > 0 {
		return n
	}
	if ppid <= 1 {
		return 0 // orphaned (reparented to launchd): unknown
	}
	if isShell(name(ppid)) {
		if p := parent(ppid); p > 1 {
			return p
		}
	}
	return ppid
}

func isShell(comm string) bool {
	comm = strings.TrimPrefix(filepath.Base(strings.TrimSpace(comm)), "-")
	switch comm {
	case "sh", "bash", "zsh", "dash", "fish":
		return true
	}
	return false
}
