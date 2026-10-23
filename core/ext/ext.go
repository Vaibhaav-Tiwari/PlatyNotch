// Package ext is the extension point of the core. The Pro edition and
// third-party integrations implement Extension and are started by the server
// with a Host that exposes state, approvals, policy, audit and memory.
package ext

import (
	"context"
	"encoding/json"
	"time"

	"github.com/platynotch/platynotch/core/config"
	"github.com/platynotch/platynotch/core/memory"
	"github.com/platynotch/platynotch/core/policy"
	"github.com/platynotch/platynotch/core/protocol"
)

// AuditEvent records one approval decision (by a human, a policy or a timeout).
type AuditEvent struct {
	At                                                   time.Time
	Agent, Project, CWD, Tool, Summary, Decision, Source string
}

// Auditor receives every approval decision. Record runs on the hook's
// goroutine; implementations should return quickly.
type Auditor interface {
	Record(AuditEvent)
}

// Host is the core as seen by an extension.
type Host interface {
	Edition() string
	Snapshot() protocol.Snapshot
	// Subscribe delivers every broadcast envelope (the same stream UI clients
	// get) to fn on a dedicated goroutine. Events are dropped, not queued
	// without bound, if fn falls far behind.
	Subscribe(fn func(protocol.Envelope)) (cancel func())
	// Decide answers a pending approval; Behavior must be allow or deny.
	Decide(d protocol.ApprovalDecide) error
	// RegisterDecider counts as "someone can answer", so hooks wait for a
	// decision even when no UI is connected.
	RegisterDecider(name string) (unregister func())
	Memory() memory.Service // nil when memory is off
	Config() config.Config
	AddPolicy(p policy.Provider) // evaluated before local rules, in order added
	AddAuditor(a Auditor)
	EmitEvent(ext, kind string, data any) // ext.event to UIs
	Logf(format string, args ...any)
}

// Extension is started once when the server starts serving.
type Extension interface {
	Name() string
	Start(ctx context.Context, h Host) error
}

// RequestHandler is optionally implemented by an Extension to answer
// ext.request messages whose ext field equals its Name.
type RequestHandler interface {
	HandleRequest(ctx context.Context, kind string, data json.RawMessage) (any, error)
}
