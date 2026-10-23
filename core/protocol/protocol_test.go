package protocol

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "rewrite testdata/*.json golden fixtures")

func TestEnvelopeRoundTrip(t *testing.T) {
	want := Approval{ID: "apr_1", Tool: "Bash", Summary: "npm test"}
	env := MustNew(TypeApprovalAdded, "1", want)
	b, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	var back Envelope
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	var got Approval
	if err := back.Decode(&got); err != nil {
		t.Fatal(err)
	}
	if back.Type != TypeApprovalAdded || back.ID != "1" || back.V != Version {
		t.Fatalf("bad envelope: %+v", back)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v want %+v", got, want)
	}
}

func ts(s string) time.Time {
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return v.UTC()
}

func tsp(s string) *time.Time { v := ts(s); return &v }

func TestGoldenFixtures(t *testing.T) {
	t0 := "2026-10-23T10:00:00Z"
	t1 := "2026-10-23T10:05:00Z"
	session := Session{
		Key: "claude-code:abc123", Agent: "claude-code", AgentName: "Claude Code",
		SessionID: "abc123", CWD: "/Users/dev/platynotch", Project: "platynotch",
		State: StateWaitingInput, Title: "Fix the failing test", Tool: "Bash",
		Message: "Waiting for approval", PID: 4242, TTY: "ttys004",
		TermProgram: "Apple_Terminal", Subagents: 1, StartedAt: ts(t0), UpdatedAt: ts(t1),
	}
	approval := Approval{
		ID: "apr_1", SessionKey: "claude-code:abc123", Agent: "claude-code",
		AgentName: "Claude Code", Project: "platynotch", CWD: "/Users/dev/platynotch",
		Tool: "Bash", Summary: "npm test",
		Input:     json.RawMessage(`{"command":"npm test"}`),
		CreatedAt: ts(t1), ExpiresAt: ts("2026-10-23T10:06:40Z"),
	}
	usage := Usage{
		Claude: &Limits{
			FiveHour:  &Window{UsedPercent: 42.5, ResetsAt: tsp("2026-10-23T14:00:00Z")},
			Weekly:    &Window{UsedPercent: 12, ResetsAt: tsp("2026-10-27T00:00:00Z")},
			Extra:     map[string]Window{"seven_day_opus": {UsedPercent: 3.5}},
			UpdatedAt: ts(t1),
		},
		Codex: &Limits{FiveHour: &Window{UsedPercent: 8}, UpdatedAt: ts(t1)},
	}
	loop := Loop{
		ID: "loop_1", Title: "Send the budget draft to Sam", Details: "Promised in Slack",
		Kind: "commitment", Status: "open", SourceApp: "Slack", SourceThread: "thr_9",
		Quote: "I'll send it over tomorrow", DueAt: tsp("2026-10-24T17:00:00Z"),
		DetectedAt: ts(t0),
	}
	hit := MemoryHit{
		ThreadID: "thr_9", Title: "Budget chat with Sam", SourceApp: "Slack",
		Snippet: "I'll send it over tomorrow", Score: 0.87, At: ts(t0),
	}
	snapshot := Snapshot{
		Sessions: []Session{session}, Approvals: []Approval{approval}, Usage: usage,
		Loops:   []Loop{loop},
		Memory:  MemoryStatus{Enabled: true, Threads: 3, Versions: 5, Chunks: 20, Pending: 2, Embedder: "ollama", Extractor: "none"},
		Edition: "free",
	}
	hookEvent := HookEvent{
		Agent: "claude-code", Event: "permission-request",
		Payload: json.RawMessage(`{"tool_name":"Bash","tool_input":{"command":"npm test"}}`),
		PID:     4242, PPID: 4200, TTY: "ttys004", CWD: "/Users/dev/platynotch",
		TermProgram: "Apple_Terminal", WantDecision: true, At: ts(t1),
	}
	decision := HookDecision{Behavior: BehaviorDeny, Message: "Blocked by policy", Source: "policy"}
	ext := ExtMessage{Ext: "example-ext", Kind: "ping", Data: json.RawMessage(`{"n":1}`)}
	removed := SessionRemoved{Key: "claude-code:abc123"}

	fixtures := map[string]any{
		"snapshot": snapshot, "session": session, "approval": approval,
		"hook_event": hookEvent, "hook_decision": decision, "usage": usage,
		"loop": loop, "memory_hit": hit, "ext_message": ext,
		"session_removed": removed,
	}
	for name, v := range fixtures {
		t.Run(name, func(t *testing.T) {
			got, err := json.MarshalIndent(v, "", "  ")
			if err != nil {
				t.Fatal(err)
			}
			got = append(got, '\n')
			path := filepath.Join("testdata", name+".json")
			if *update {
				if err := os.MkdirAll("testdata", 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, got, 0o644); err != nil {
					t.Fatal(err)
				}
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != string(want) {
				t.Fatalf("%s mismatch\n got: %s\nwant: %s", path, got, want)
			}
		})
	}
}
