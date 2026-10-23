package server

import (
	"context"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/ext"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/session"
)

const defaultApprovalTimeout = 100 * time.Second

// handleHook runs one hook.event to completion: state update, then (for a
// permission event that wants a decision) policy, then the human approval.
// Every reply carries the event's envelope ID.
func (s *Server) handleHook(ctx context.Context, c *conn, env protocol.Envelope) {
	id := env.ID
	var ev protocol.HookEvent
	if err := env.Decode(&ev); err != nil {
		c.writeNow(protocol.TypeError, id, protocol.ErrorMsg{Message: "bad hook.event: " + err.Error()})
		return
	}
	a, ok := agents.Get(ev.Agent)
	if !ok {
		c.writeNow(protocol.TypeError, id, protocol.ErrorMsg{Message: "unknown agent " + ev.Agent})
		return
	}
	common := a.ParseCommon(ev.Event, ev.Payload)
	sess := s.applyHook(ev, a, common)
	noWait := func() { c.writeNow(protocol.TypeHookAck, id, protocol.HookAck{Wait: false}) }

	cfg := s.Config()
	if !ev.WantDecision || !a.IsPermissionEvent(ev.Event) ||
		a.Approvals() == agents.ApprovalsNone || !cfg.ApprovalsOn(ev.Agent) {
		noWait()
		return
	}
	// A permission event must name its own tool. An unreadable, truncated or
	// empty payload never reaches policy (a catch-all allow rule would allow
	// it) or a human (who would see a blank prompt); the agent then asks in
	// its own terminal. The session's earlier tool is never borrowed.
	if common.Tool == "" {
		noWait()
		return
	}

	tool := common.Tool
	// Policy sees the whole command; people see the shortened summary. A
	// truncated summary could hide "; curl x | sh" past the cut from an
	// allow rule's compound-command guard.
	full, kind := agents.PolicySummary(a, ev.Event, ev.Payload, common)
	summary := agents.Summarize(tool, common.ToolInput)
	audit := ext.AuditEvent{
		Agent: ev.Agent, Project: sess.Project, CWD: sess.CWD, Tool: tool, Summary: summary,
	}

	s.mu.Lock()
	chain := append(policy.Chain(nil), s.policies...)
	s.mu.Unlock()
	chain = append(chain, policy.Local(cfg.Policy.Rules))
	if v, ok := chain.EvaluateKind(tool, full, kind); ok && (v.Action == protocol.BehaviorAllow || v.Action == protocol.BehaviorDeny) {
		if v.Source == "" {
			v.Source = "policy"
		}
		d := protocol.HookDecision{Behavior: v.Action, Message: v.Reason, Source: v.Source}
		if c.writeNow(protocol.TypeHookAck, id, protocol.HookAck{Wait: true}) == nil {
			c.writeNow(protocol.TypeHookDecision, id, d)
		}
		s.resolveSession(sess.Key)
		audit.At, audit.Decision, audit.Source = s.now(), d.Behavior, d.Source
		s.audit(audit)
		return
	}
	// "ask" or no verdict: a human decides, if anyone can.

	timeout := time.Duration(cfg.Approvals.TimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = defaultApprovalTimeout
	}
	s.mu.Lock()
	if s.decidersLocked() == 0 {
		s.mu.Unlock()
		noWait()
		return
	}
	appr, ch := s.mgr.Open(protocol.Approval{
		SessionKey: sess.Key, Agent: ev.Agent, AgentName: a.Name(),
		Project: sess.Project, CWD: sess.CWD, Tool: tool, Summary: summary,
		Input: common.ToolInput, ExpiresAt: s.now().Add(timeout),
	})
	s.broadcastLocked(protocol.MustNew(protocol.TypeApprovalAdded, "", appr))
	s.mu.Unlock()

	gone := c.watchGone()
	ackErr := c.writeNow(protocol.TypeHookAck, id, protocol.HookAck{
		Wait: true, ApprovalID: appr.ID, TimeoutMS: int(timeout / time.Millisecond),
	})

	var d protocol.HookDecision
	timedOut, hookGone := false, ackErr != nil
	if hookGone {
		s.mgr.ExpireWith(appr.ID, "hook-gone")
		d = <-ch
	} else {
		timer := time.NewTimer(timeout)
		decided := false
		select {
		case d = <-ch:
			decided = true
		case <-timer.C:
			timedOut = true
		case <-gone:
			hookGone = true
		case <-ctx.Done():
		}
		timer.Stop()
		if !decided {
			reason := "shutdown"
			switch {
			case timedOut:
				reason = "timeout"
			case hookGone:
				reason = "hook-gone"
			}
			// Expiry loses only to a decision that raced in; either way
			// exactly one decision is now buffered on ch.
			s.mgr.ExpireWith(appr.ID, reason)
			d = <-ch
		}
	}
	if d.Behavior != protocol.BehaviorNone {
		timedOut = false
	}

	s.broadcast(protocol.MustNew(protocol.TypeApprovalResolved, "", protocol.ApprovalResolved{
		ID: appr.ID, Behavior: d.Behavior, Source: d.Source,
	}))
	if !hookGone {
		c.writeNow(protocol.TypeHookDecision, id, d)
	}
	if d.Behavior == protocol.BehaviorAllow || d.Behavior == protocol.BehaviorDeny {
		s.resolveSession(sess.Key)
	}
	if timedOut {
		s.broadcast(protocol.MustNew(protocol.TypeNotice, "", protocol.Notice{
			Kind: "approval-timeout", Title: a.Name() + " is asking in its terminal",
			Body: summary, SessionKey: sess.Key,
		}))
	}
	audit.At, audit.Decision, audit.Source = s.now(), d.Behavior, d.Source
	s.audit(audit)
}

// applyHook folds the event into the store, broadcasts the change, and emits
// a notice when an active session stops.
func (s *Server) applyHook(ev protocol.HookEvent, a agents.Adapter, common agents.Common) protocol.Session {
	key := session.Key(ev.Agent, common.SessionID, ev.PID)
	s.mu.Lock()
	defer s.mu.Unlock()
	prev, had := s.store.Get(key)
	sess, changed := s.store.Apply(ev, a)
	if changed {
		s.broadcastLocked(protocol.MustNew(protocol.TypeSessionUpdated, "", sess))
	}
	if had && prev.State == protocol.StateActive && sess.State == protocol.StateIdle &&
		(ev.Event == "stop" || ev.Event == "stop-failure") {
		n := protocol.Notice{Kind: "session-done", Title: sess.AgentName + " finished", SessionKey: sess.Key}
		if ev.Event == "stop-failure" {
			n.Kind, n.Title = "session-failed", sess.AgentName+" stopped with an error"
		}
		n.Body = firstNonEmpty(sess.Title, sess.Project)
		s.broadcastLocked(protocol.MustNew(protocol.TypeNotice, "", n))
	}
	return sess
}

func (s *Server) resolveSession(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sess, ok := s.store.Resolve(key); ok {
		s.broadcastLocked(protocol.MustNew(protocol.TypeSessionUpdated, "", sess))
	}
}

func firstNonEmpty(v ...string) string {
	for _, x := range v {
		if x != "" {
			return x
		}
	}
	return ""
}
