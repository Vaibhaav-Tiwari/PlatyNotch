// Package protocol defines the newline-delimited JSON messages exchanged over
// the PlatyNotch core socket. Every client (agent hooks, the Mac app, capture,
// the CLI, Pro extensions) speaks this protocol; docs/PROTOCOL.md is the
// human-readable copy and must be kept in sync.
package protocol

import (
	"encoding/json"
	"time"
)

// Version is bumped on any incompatible change to a message shape.
const Version = 1

// Envelope wraps every message on the wire: one JSON object per line.
type Envelope struct {
	V    int             `json:"v"`
	Type string          `json:"type"`
	ID   string          `json:"id,omitempty"` // correlates a request with its reply
	Data json.RawMessage `json:"data,omitempty"`
}

// Message types.
const (
	TypeHello = "hello" // client → core, first message on every connection
	TypePing  = "ping"
	TypePong  = "pong"
	TypeError = "error"

	// Agent hooks.
	TypeHookEvent    = "hook.event"    // hook → core
	TypeHookAck      = "hook.ack"      // core → hook: whether to wait for a decision
	TypeHookDecision = "hook.decision" // core → hook

	// UI clients.
	TypeSubscribe        = "subscribe"         // ui → core; core replies with snapshot, then streams updates
	TypeSnapshot         = "snapshot"          // core → ui
	TypeSessionUpdated   = "session.updated"   // core → ui
	TypeSessionRemoved   = "session.removed"   // core → ui
	TypeApprovalAdded    = "approval.added"    // core → ui
	TypeApprovalResolved = "approval.resolved" // core → ui
	TypeApprovalDecide   = "approval.decide"   // ui → core
	TypeUsageUpdated     = "usage.updated"     // core → ui
	TypeLoopsUpdated     = "loops.updated"     // core → ui
	TypeLoopSetStatus    = "loop.set_status"   // ui → core
	TypeNotice           = "notice"            // core → ui
	TypeMemoryStatus     = "memory.status"     // core → ui
	TypeConfigReload     = "config.reload"     // ui/cli → core

	// Memory.
	TypeCaptureText   = "capture.text"   // capture → core
	TypeMemorySearch  = "memory.search"  // any → core
	TypeMemoryResults = "memory.results" // core → requester

	// Extensions (Pro and third-party): opaque, namespaced messages.
	TypeExtRequest = "ext.request" // ext/ui → core → extension handler
	TypeExtEvent   = "ext.event"   // extension → ui/ext subscribers
)

// Client roles sent in Hello.
const (
	RoleHook    = "hook"
	RoleUI      = "ui"
	RoleCapture = "capture"
	RoleCLI     = "cli"
	RoleExt     = "ext"
)

// Session activity states (same five states as agent-orchestrator).
type State string

const (
	StateActive       State = "active"
	StateIdle         State = "idle"
	StateWaitingInput State = "waiting_input"
	StateBlocked      State = "blocked"
	StateExited       State = "exited"
)

// Decision behaviors.
const (
	BehaviorAllow = "allow"
	BehaviorDeny  = "deny"
	BehaviorNone  = "none" // no answer: the agent asks in its own terminal
)

type Hello struct {
	Role    string `json:"role"`
	Client  string `json:"client,omitempty"` // e.g. "notch-hook/0.1.0"
	Version int    `json:"version"`
}

type ErrorMsg struct {
	Message string `json:"message"`
}

// HookEvent is sent by `notch hook <agent> <event>` for every agent hook call.
type HookEvent struct {
	Agent        string          `json:"agent"` // adapter id, e.g. "claude-code"
	Event        string          `json:"event"` // normalized kebab-case event, e.g. "permission-request"
	Payload      json.RawMessage `json:"payload,omitempty"`
	PID          int             `json:"pid,omitempty"`  // the agent's process (CLAUDE_PID, else hook's grandparent)
	PPID         int             `json:"ppid,omitempty"` // hook's parent
	TTY          string          `json:"tty,omitempty"`  // e.g. "ttys004"
	CWD          string          `json:"cwd,omitempty"`
	TermProgram  string          `json:"term_program,omitempty"` // $TERM_PROGRAM
	WantDecision bool            `json:"want_decision,omitempty"`
	At           time.Time       `json:"at"`
}

type HookAck struct {
	Wait       bool   `json:"wait"`
	ApprovalID string `json:"approval_id,omitempty"`
	TimeoutMS  int    `json:"timeout_ms,omitempty"`
}

type HookDecision struct {
	Behavior string `json:"behavior"` // allow | deny | none
	Message  string `json:"message,omitempty"`
	Source   string `json:"source,omitempty"` // "notch", "phone", "policy", "slack", ...
}

// Session is one running agent conversation.
type Session struct {
	Key         string    `json:"key"` // agent + ":" + session id
	Agent       string    `json:"agent"`
	AgentName   string    `json:"agent_name"`
	SessionID   string    `json:"session_id"`
	CWD         string    `json:"cwd,omitempty"`
	Project     string    `json:"project,omitempty"` // basename of cwd
	State       State     `json:"state"`
	Title       string    `json:"title,omitempty"` // last user prompt, truncated
	Tool        string    `json:"tool,omitempty"`  // tool currently running or blocking
	Message     string    `json:"message,omitempty"`
	PID         int       `json:"pid,omitempty"`
	TTY         string    `json:"tty,omitempty"`
	TermProgram string    `json:"term_program,omitempty"`
	Subagents   int       `json:"subagents,omitempty"`
	StartedAt   time.Time `json:"started_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// SessionRemoved is the payload of session.removed.
type SessionRemoved struct {
	Key string `json:"key"`
}

// Approval is a pending permission request waiting for a human decision.
type Approval struct {
	ID         string          `json:"id"`
	SessionKey string          `json:"session_key"`
	Agent      string          `json:"agent"`
	AgentName  string          `json:"agent_name"`
	Project    string          `json:"project,omitempty"`
	CWD        string          `json:"cwd,omitempty"`
	Tool       string          `json:"tool"`
	Summary    string          `json:"summary"` // exact command or file path, never paraphrased
	Input      json.RawMessage `json:"input,omitempty"`
	CreatedAt  time.Time       `json:"created_at"`
	ExpiresAt  time.Time       `json:"expires_at"`
}

type ApprovalDecide struct {
	ID       string `json:"id"`
	Behavior string `json:"behavior"`
	Message  string `json:"message,omitempty"`
	Source   string `json:"source,omitempty"`
}

type ApprovalResolved struct {
	ID       string `json:"id"`
	Behavior string `json:"behavior"`
	Source   string `json:"source,omitempty"`
}

// Usage limits read from Claude Code's status line and Codex rollouts.
type Window struct {
	UsedPercent float64    `json:"used_percent"`
	ResetsAt    *time.Time `json:"resets_at,omitempty"`
}

type Limits struct {
	FiveHour  *Window           `json:"five_hour,omitempty"`
	Weekly    *Window           `json:"weekly,omitempty"`
	Extra     map[string]Window `json:"extra,omitempty"` // e.g. "seven_day_opus"
	UpdatedAt time.Time         `json:"updated_at"`
}

type Usage struct {
	Claude *Limits `json:"claude,omitempty"`
	Codex  *Limits `json:"codex,omitempty"`
}

// Loop is an open loop (commitment or action item) found in memory.
type Loop struct {
	ID           string     `json:"id"`
	Title        string     `json:"title"`
	Details      string     `json:"details,omitempty"`
	Kind         string     `json:"kind"`   // "commitment" | "request" | "followup" | "task"
	Status       string     `json:"status"` // "open" | "resolved" | "dismissed"
	SourceApp    string     `json:"source_app,omitempty"`
	SourceThread string     `json:"source_thread,omitempty"`
	Quote        string     `json:"quote,omitempty"`
	DueAt        *time.Time `json:"due_at,omitempty"`
	DetectedAt   time.Time  `json:"detected_at"`
	ResolvedAt   *time.Time `json:"resolved_at,omitempty"`
	Evidence     string     `json:"evidence,omitempty"`
}

type LoopSetStatus struct {
	ID       string `json:"id"`
	Status   string `json:"status"`
	Evidence string `json:"evidence,omitempty"`
}

type MemoryStatus struct {
	Enabled   bool   `json:"enabled"`
	Threads   int    `json:"threads"`
	Versions  int    `json:"versions"`
	Chunks    int    `json:"chunks"`
	Pending   int    `json:"pending"` // chunks waiting for embeddings or extraction
	Embedder  string `json:"embedder"`
	Extractor string `json:"extractor"`
	LastError string `json:"last_error,omitempty"`
}

// CaptureText is on-screen text read through the Accessibility API.
type CaptureText struct {
	AppBundle   string    `json:"app_bundle"`
	AppName     string    `json:"app_name"`
	WindowTitle string    `json:"window_title,omitempty"`
	URL         string    `json:"url,omitempty"`
	Text        string    `json:"text"`
	CapturedAt  time.Time `json:"captured_at"`
}

type MemorySearch struct {
	Query string     `json:"query"`
	Limit int        `json:"limit,omitempty"`
	Since *time.Time `json:"since,omitempty"`
	Until *time.Time `json:"until,omitempty"`
	App   string     `json:"app,omitempty"`
}

type MemoryHit struct {
	ThreadID  string    `json:"thread_id"`
	Title     string    `json:"title"`
	SourceApp string    `json:"source_app"`
	Snippet   string    `json:"snippet"`
	Score     float64   `json:"score"`
	At        time.Time `json:"at"`
}

type MemoryResults struct {
	Hits []MemoryHit `json:"hits"`
}

type Notice struct {
	Kind       string `json:"kind"` // "session-done", "session-failed", "approval-timeout", "info"
	Title      string `json:"title"`
	Body       string `json:"body,omitempty"`
	SessionKey string `json:"session_key,omitempty"`
}

// Snapshot is the full state sent to a UI client on subscribe.
type Snapshot struct {
	Sessions  []Session    `json:"sessions"`
	Approvals []Approval   `json:"approvals"`
	Usage     Usage        `json:"usage"`
	Loops     []Loop       `json:"loops"`
	Memory    MemoryStatus `json:"memory"`
	Edition   string       `json:"edition"` // "free" or "pro"
}

// ExtMessage is the payload of ext.request and ext.event. The core routes by
// Ext (the extension id) and never interprets Kind or Data.
type ExtMessage struct {
	Ext  string          `json:"ext"`            // extension id, e.g. "platynotch-cloud"
	Kind string          `json:"kind"`           // extension-defined message kind
	Data json.RawMessage `json:"data,omitempty"` // extension-defined payload
}

// New builds an envelope with a marshalled payload.
func New(typ, id string, data any) (Envelope, error) {
	env := Envelope{V: Version, Type: typ, ID: id}
	if data != nil {
		raw, err := json.Marshal(data)
		if err != nil {
			return env, err
		}
		env.Data = raw
	}
	return env, nil
}

// MustNew is New for payloads that cannot fail to marshal.
func MustNew(typ, id string, data any) Envelope {
	env, err := New(typ, id, data)
	if err != nil {
		panic(err)
	}
	return env
}

// Decode unmarshals the envelope payload into v.
func (e Envelope) Decode(v any) error {
	if len(e.Data) == 0 {
		return nil
	}
	return json.Unmarshal(e.Data, v)
}
