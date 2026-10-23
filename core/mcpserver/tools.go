package mcpserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/loops"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/search"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

const (
	maxSearchLimit = 20
	defaultHours   = 24
	maxActivity    = 500
)

type searchIn struct {
	Query string `json:"query" jsonschema:"what to look for in the user's screen history"`
	Since string `json:"since,omitempty" jsonschema:"only results at or after this RFC 3339 time"`
	Until string `json:"until,omitempty" jsonschema:"only results at or before this RFC 3339 time"`
	App   string `json:"app,omitempty" jsonschema:"restrict to one app, by name or bundle id"`
	Limit int    `json:"limit,omitempty" jsonschema:"maximum number of hits, at most 20"`
}

type searchHit struct {
	Title    string `json:"title"`
	App      string `json:"app"`
	At       string `json:"at"`
	Snippet  string `json:"snippet"`
	ThreadID string `json:"thread_id"`
}

type searchOut struct {
	Hits []searchHit `json:"hits"`
}

type loopsIn struct {
	Status string `json:"status,omitempty" jsonschema:"open (default), resolved or stale"`
}

type loopsOut struct {
	Loops []protocol.Loop `json:"loops"`
}

type threadIn struct {
	ThreadID string `json:"thread_id" jsonschema:"thread id from search_memory or recent_activity"`
	Hours    int    `json:"hours,omitempty" jsonschema:"how many hours of versions to include, default 24"`
}

type threadOut struct {
	ThreadID  string `json:"thread_id"`
	Title     string `json:"title"`
	App       string `json:"app"`
	Text      string `json:"text"`
	Truncated bool   `json:"truncated"`
}

type activityIn struct {
	Hours int `json:"hours,omitempty" jsonschema:"look-back window in hours, default 24"`
}

type activityThread struct {
	ThreadID  string `json:"thread_id"`
	Title     string `json:"title"`
	UpdatedAt string `json:"updated_at"`
}

type activityApp struct {
	App     string           `json:"app"`
	Threads []activityThread `json:"threads"`
}

type activityOut struct {
	Hours int           `json:"hours"`
	Apps  []activityApp `json:"apps"`
}

type resolveIn struct {
	ID       string `json:"id" jsonschema:"loop id from list_open_loops"`
	Evidence string `json:"evidence" jsonschema:"why the loop is done, e.g. what the user did"`
}

type resolveOut struct {
	OK bool   `json:"ok"`
	ID string `json:"id"`
}

func registerTools(s *mcp.Server, d Deps) {
	mcp.AddTool(s, &mcp.Tool{Name: "search_memory", Description: "Search what the user saw, read or wrote on their screen. Returns matching snippets with the app, time and thread id."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in searchIn) (*mcp.CallToolResult, any, error) {
			out, err := doSearch(ctx, d, in)
			return nil, out, err
		})
	mcp.AddTool(s, &mcp.Tool{Name: "list_open_loops", Description: "List commitments, requests and follow-ups detected in the user's screen history."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in loopsIn) (*mcp.CallToolResult, any, error) {
			out, err := doLoops(d, in)
			return nil, out, err
		})
	mcp.AddTool(s, &mcp.Tool{Name: "get_thread", Description: "Read the recent text of one thread (a window, document or conversation), up to 20000 characters."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in threadIn) (*mcp.CallToolResult, any, error) {
			out, err := doThread(d, in)
			return nil, out, err
		})
	mcp.AddTool(s, &mcp.Tool{Name: "recent_activity", Description: "Threads the user touched recently, grouped by app, with titles."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in activityIn) (*mcp.CallToolResult, any, error) {
			out, err := doActivity(d, in)
			return nil, out, err
		})
	mcp.AddTool(s, &mcp.Tool{Name: "resolve_loop", Description: "Mark an open loop as resolved, with evidence. Needs PlatyNotch to be running."},
		func(ctx context.Context, _ *mcp.CallToolRequest, in resolveIn) (*mcp.CallToolResult, any, error) {
			out, err := doResolve(ctx, d, in)
			return nil, out, err
		})
}

// CallTool runs the named tool with JSON arguments and returns its result
// value (marshal it for the wire). It is the dispatcher behind the MCP tools,
// exported so other transports answer with identical behavior. Errors are
// tool errors; their text is meant for the model.
func CallTool(ctx context.Context, deps Deps, name string, args json.RawMessage) (any, error) {
	if len(args) == 0 {
		args = json.RawMessage(`{}`)
	}
	switch name {
	case "search_memory":
		return callTyped(args, func(in searchIn) (any, error) { return doSearch(ctx, deps, in) })
	case "list_open_loops":
		return callTyped(args, func(in loopsIn) (any, error) { return doLoops(deps, in) })
	case "get_thread":
		return callTyped(args, func(in threadIn) (any, error) { return doThread(deps, in) })
	case "recent_activity":
		return callTyped(args, func(in activityIn) (any, error) { return doActivity(deps, in) })
	case "resolve_loop":
		return callTyped(args, func(in resolveIn) (any, error) { return doResolve(ctx, deps, in) })
	}
	return nil, fmt.Errorf("unknown tool %q", name)
}

func callTyped[In any](args json.RawMessage, f func(In) (any, error)) (any, error) {
	var in In
	if err := json.Unmarshal(args, &in); err != nil {
		return nil, fmt.Errorf("invalid arguments: %w", err)
	}
	return f(in)
}

var errMemoryOff = errors.New(MsgMemoryOff)

func parseTime(field, v string) (*time.Time, error) {
	if v == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		return nil, fmt.Errorf("%s must be an RFC 3339 time such as 2026-01-02T15:04:05Z", field)
	}
	return &t, nil
}

func hoursOrDefault(h int) int {
	if h <= 0 {
		return defaultHours
	}
	return h
}

func doSearch(ctx context.Context, d Deps, in searchIn) (any, error) {
	if d.Store == nil {
		return nil, errMemoryOff
	}
	since, err := parseTime("since", in.Since)
	if err != nil {
		return nil, err
	}
	until, err := parseTime("until", in.Until)
	if err != nil {
		return nil, err
	}
	limit := in.Limit
	if limit <= 0 || limit > maxSearchLimit {
		limit = maxSearchLimit
	}
	hits, err := search.Search(ctx, d.Store, d.Embedder, protocol.MemorySearch{Query: in.Query, Limit: limit, Since: since, Until: until, App: in.App})
	if err != nil {
		return nil, fmt.Errorf("search failed: %w", err)
	}
	out := searchOut{Hits: make([]searchHit, 0, len(hits))}
	for _, h := range hits {
		out.Hits = append(out.Hits, searchHit{Title: h.Title, App: h.SourceApp, At: h.At.Format(time.RFC3339), Snippet: h.Snippet, ThreadID: h.ThreadID})
	}
	return out, nil
}

func doLoops(d Deps, in loopsIn) (any, error) {
	if d.Store == nil {
		return nil, errMemoryOff
	}
	status := in.Status
	if status == "" {
		status = "open"
	}
	switch status {
	case "open", "resolved", "stale":
	default:
		return nil, fmt.Errorf("status must be open, resolved or stale, got %q", status)
	}
	ls, err := loops.List(d.Store, status)
	if err != nil {
		return nil, fmt.Errorf("list loops failed: %w", err)
	}
	if ls == nil {
		ls = []protocol.Loop{}
	}
	return loopsOut{Loops: ls}, nil
}

func doThread(d Deps, in threadIn) (any, error) {
	if d.Store == nil {
		return nil, errMemoryOff
	}
	if in.ThreadID == "" {
		return nil, errors.New("thread_id is required")
	}
	th, ok, err := d.Store.GetThread(in.ThreadID)
	if err != nil {
		return nil, fmt.Errorf("read thread failed: %w", err)
	}
	if !ok {
		return nil, fmt.Errorf("no thread with id %q", in.ThreadID)
	}
	since := time.Now().Add(-time.Duration(hoursOrDefault(in.Hours)) * time.Hour)
	vs, err := d.Store.ThreadVersions(th.ID, since)
	if err != nil {
		return nil, fmt.Errorf("read thread failed: %w", err)
	}
	parts := make([]string, len(vs))
	for i, v := range vs {
		parts[i] = "[" + v.CreatedAt.Format(time.RFC3339) + "]\n" + v.Content
	}
	txt, truncated := truncate(strings.Join(parts, "\n\n"), maxThreadChars)
	app := th.AppName
	if app == "" {
		app = th.AppBundle
	}
	return threadOut{ThreadID: th.ID, Title: th.Title, App: app, Text: txt, Truncated: truncated}, nil
}

func truncate(s string, n int) (string, bool) {
	r := []rune(s)
	if len(r) <= n {
		return s, false
	}
	return string(r[:n]) + fmt.Sprintf("\n\n[truncated: %d more characters not shown]", len(r)-n), true
}

func doActivity(d Deps, in activityIn) (any, error) {
	if d.Store == nil {
		return nil, errMemoryOff
	}
	hours := hoursOrDefault(in.Hours)
	ts, err := d.Store.ThreadsUpdatedSince(time.Now().Add(-time.Duration(hours)*time.Hour), maxActivity)
	if err != nil {
		return nil, fmt.Errorf("recent activity failed: %w", err)
	}
	byApp := map[string]*activityApp{}
	var order []string
	for _, t := range ts {
		app := t.AppName
		if app == "" {
			app = t.AppBundle
		}
		a := byApp[app]
		if a == nil {
			a = &activityApp{App: app}
			byApp[app] = a
			order = append(order, app)
		}
		a.Threads = append(a.Threads, activityThread{ThreadID: t.ID, Title: t.Title, UpdatedAt: t.UpdatedAt.Format(time.RFC3339)})
	}
	sort.Strings(order)
	out := activityOut{Hours: hours, Apps: make([]activityApp, 0, len(order))}
	for _, k := range order {
		out.Apps = append(out.Apps, *byApp[k])
	}
	return out, nil
}

func doResolve(ctx context.Context, d Deps, in resolveIn) (any, error) {
	if d.Store == nil {
		return nil, errMemoryOff
	}
	if in.ID == "" {
		return nil, errors.New("id is required")
	}
	if d.Resolve == nil {
		return nil, errors.New(MsgCoreNotUp)
	}
	if err := d.Resolve(ctx, protocol.LoopSetStatus{ID: in.ID, Status: "resolved", Evidence: in.Evidence}); err != nil {
		if isCoreDown(err) {
			return nil, errors.New(MsgCoreNotUp)
		}
		return nil, err
	}
	return resolveOut{OK: true, ID: in.ID}, nil
}

// isCoreDown reports whether err means the core could not be reached.
func isCoreDown(err error) bool {
	var ne net.Error
	if errors.Is(err, ErrCoreDown) || errors.As(err, &ne) {
		return true
	}
	m := strings.ToLower(err.Error())
	for _, s := range []string{"not running", "connection refused", "no such file", "dial "} {
		if strings.Contains(m, s) {
			return true
		}
	}
	return false
}
