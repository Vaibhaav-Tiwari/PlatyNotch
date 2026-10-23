// Package agents defines the contract every coding-agent integration
// implements, plus a package-level registry adapters join from init().
package agents

import (
	"encoding/json"
	"sort"
	"sync"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// ApprovalSupport says how far approve-from-the-notch is trusted for an agent.
type ApprovalSupport int

const (
	ApprovalsNone ApprovalSupport = iota
	ApprovalsExperimental
	ApprovalsVerified
)

// Common holds the fields every agent's hook payload is normalized into.
type Common struct {
	SessionID, CWD, Tool, ToolUseID, Prompt, Message, NotificationType, TranscriptPath string
	ToolInput                                                                          json.RawMessage
}

// Adapter is one coding-agent integration.
type Adapter interface {
	ID() string   // "claude-code"
	Name() string // "Claude Code"
	Detect() bool // config dir exists or binary on PATH
	ConfigPath() string
	InstallHooks(hookBin string) (bool, error)
	UninstallHooks() (bool, error)
	HooksInstalled() (bool, error)
	DeriveState(event string, payload []byte) (protocol.State, bool)
	ParseCommon(event string, payload []byte) Common
	Approvals() ApprovalSupport
	IsPermissionEvent(event string) bool
	FormatDecision(event string, d protocol.HookDecision) []byte // nil: print nothing
}

var (
	mu       sync.RWMutex
	registry = map[string]Adapter{}
)

// Register adds (or replaces) an adapter. Safe to call from init().
func Register(a Adapter) {
	mu.Lock()
	defer mu.Unlock()
	registry[a.ID()] = a
}

// Get returns the adapter with the given ID.
func Get(id string) (Adapter, bool) {
	mu.RLock()
	defer mu.RUnlock()
	a, ok := registry[id]
	return a, ok
}

// All returns every registered adapter sorted by ID.
func All() []Adapter {
	mu.RLock()
	defer mu.RUnlock()
	out := make([]Adapter, 0, len(registry))
	for _, a := range registry {
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID() < out[j].ID() })
	return out
}
