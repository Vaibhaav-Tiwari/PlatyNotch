// Package approval tracks pending permission requests and delivers exactly one
// decision for each.
package approval

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sort"
	"sync"
	"time"

	"github.com/platynotch/platynotch/core/protocol"
)

var (
	ErrUnknown  = errors.New("approval: unknown id")
	ErrResolved = errors.New("approval: already resolved")
)

const (
	defaultTimeout = 100 * time.Second
	resolvedKeep   = 10 * time.Minute
)

type entry struct {
	approval   protocol.Approval
	ch         chan protocol.HookDecision
	resolved   bool
	resolvedAt time.Time
}

// Manager is safe for concurrent use.
type Manager struct {
	now func() time.Time
	mu  sync.Mutex
	m   map[string]*entry
}

func NewManager(now func() time.Time) *Manager {
	if now == nil {
		now = time.Now
	}
	return &Manager{now: now, m: map[string]*entry{}}
}

func newID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return "apr_" + hex.EncodeToString(b[:])
}

// Open registers a pending approval. It assigns ID and CreatedAt, and sets
// ExpiresAt to 100 s from now unless the caller set one. The returned channel
// (buffered 1) receives exactly one decision.
func (m *Manager) Open(a protocol.Approval) (protocol.Approval, <-chan protocol.HookDecision) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	m.pruneLocked(now)
	a.ID = newID()
	for m.m[a.ID] != nil {
		a.ID = newID()
	}
	a.CreatedAt = now
	if a.ExpiresAt.IsZero() {
		a.ExpiresAt = now.Add(defaultTimeout)
	}
	e := &entry{approval: a, ch: make(chan protocol.HookDecision, 1)}
	m.m[a.ID] = e
	return a, e.ch
}

// pruneLocked forgets resolved entries after a grace period so late duplicate
// decisions still report ErrResolved without the map growing forever.
func (m *Manager) pruneLocked(now time.Time) {
	for id, e := range m.m {
		if e.resolved && now.Sub(e.resolvedAt) > resolvedKeep {
			delete(m.m, id)
		}
	}
}

func (m *Manager) resolve(id string, d protocol.HookDecision) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.m[id]
	if !ok {
		return ErrUnknown
	}
	if e.resolved {
		return ErrResolved
	}
	e.resolved = true
	e.resolvedAt = m.now()
	e.ch <- d
	return nil
}

// Decide delivers a human/phone/policy decision. Only the first call per
// approval succeeds.
func (m *Manager) Decide(d protocol.ApprovalDecide) error {
	return m.resolve(d.ID, protocol.HookDecision{Behavior: d.Behavior, Message: d.Message, Source: d.Source})
}

// Expire resolves a still-pending approval with BehaviorNone so the agent
// falls back to asking in its own terminal. It reports whether it did.
func (m *Manager) Expire(id string) bool {
	return m.resolve(id, protocol.HookDecision{Behavior: protocol.BehaviorNone, Source: "timeout"}) == nil
}

// Pending lists unresolved approvals, oldest first.
func (m *Manager) Pending() []protocol.Approval {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []protocol.Approval{}
	for _, e := range m.m {
		if !e.resolved {
			out = append(out, e.approval)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.Before(out[j].CreatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out
}
