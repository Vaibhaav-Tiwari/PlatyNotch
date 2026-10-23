package discover

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/platynotch/platynotch/core/protocol"
)

func write(t *testing.T, path, content string, mtime time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
}

func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestClaudeDiscovery(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	write(t, filepath.Join(dir, "-proj-a", "sess-new.jsonl"), fixture(t, "claude_new.jsonl"), now.Add(-time.Minute))
	write(t, filepath.Join(dir, "-proj-b", "sess-old.jsonl"), fixture(t, "claude_new.jsonl"), now.Add(-48*time.Hour))
	got := Claude(dir, now.Add(-time.Hour))
	if len(got) != 1 {
		t.Fatalf("want 1 session, got %d: %+v", len(got), got)
	}
	s := got[0]
	if s.Key != "claude-code:sess-new" || s.Agent != "claude-code" || s.AgentName != "Claude Code" ||
		s.SessionID != "sess-new" || s.CWD != "/work/demo" || s.Project != "demo" || s.State != protocol.StateIdle {
		t.Fatalf("bad session: %+v", s)
	}
	if s.Title != "second prompt" {
		t.Fatalf("title = %q", s.Title)
	}
	if want := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC); !s.StartedAt.Equal(want) {
		t.Fatalf("StartedAt = %v", s.StartedAt)
	}
	if !s.UpdatedAt.Equal(now.Add(-time.Minute).Truncate(0)) && s.UpdatedAt.Sub(now.Add(-time.Minute)) > time.Second {
		t.Fatalf("UpdatedAt = %v", s.UpdatedAt)
	}
}

func TestClaudeNoUserMessage(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "p", "x.jsonl"), `{"type":"system","cwd":"/a/b"}`+"\nnot json\n", time.Now())
	got := Claude(dir, time.Time{})
	if len(got) != 1 || got[0].Title != "" || got[0].CWD != "/a/b" {
		t.Fatalf("got %+v", got)
	}
}

func TestClaudeNewestPerSession(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	write(t, filepath.Join(dir, "p1", "same.jsonl"), `{"type":"user","cwd":"/old","message":{"content":"old"}}`+"\n", now.Add(-time.Hour))
	write(t, filepath.Join(dir, "p2", "same.jsonl"), `{"type":"user","cwd":"/new","message":{"content":"new"}}`+"\n", now)
	got := Claude(dir, time.Time{})
	if len(got) != 1 || got[0].CWD != "/new" {
		t.Fatalf("got %+v", got)
	}
}

func TestCodexDiscovery(t *testing.T) {
	dir := t.TempDir()
	now := time.Now()
	write(t, filepath.Join(dir, "2026", "01", "02", "rollout-2026-01-02T03-04-05-abc.jsonl"), fixture(t, "codex_new.jsonl"), now.Add(-time.Minute))
	write(t, filepath.Join(dir, "2025", "01", "02", "rollout-old.jsonl"), fixture(t, "codex_new.jsonl"), now.Add(-72*time.Hour))
	got := Codex(dir, now.Add(-time.Hour))
	if len(got) != 1 {
		t.Fatalf("want 1, got %+v", got)
	}
	s := got[0]
	if s.Key != "codex:codex-sess-1" || s.Agent != "codex" || s.AgentName != "Codex" || s.SessionID != "codex-sess-1" ||
		s.CWD != "/work/cx" || s.Project != "cx" || s.State != protocol.StateIdle {
		t.Fatalf("bad: %+v", s)
	}
	if s.Title != "codex follow up" {
		t.Fatalf("title = %q", s.Title)
	}
	if want := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC); !s.StartedAt.Equal(want) {
		t.Fatalf("StartedAt = %v", s.StartedAt)
	}
}

func TestMissingDirs(t *testing.T) {
	if got := Claude("/nonexistent/zzz", time.Time{}); len(got) != 0 {
		t.Fatal(got)
	}
	if got := Codex("/nonexistent/zzz", time.Time{}); len(got) != 0 {
		t.Fatal(got)
	}
}

func TestTitleTruncated(t *testing.T) {
	dir := t.TempDir()
	long := strings.Repeat("é", 120)
	write(t, filepath.Join(dir, "p", "t.jsonl"), fmt.Sprintf(`{"type":"user","message":{"content":"%s\nsecond line"}}`+"\n", long), time.Now())
	got := Claude(dir, time.Time{})
	if len(got) != 1 || len([]rune(got[0].Title)) != 80 {
		t.Fatalf("got %+v", got)
	}
}

func TestMidSizedFileNoDoubleCount(t *testing.T) {
	// 300 KB: head and tail windows overlap; must still parse cleanly.
	dir := t.TempDir()
	var b strings.Builder
	b.WriteString(`{"type":"user","cwd":"/w/mid","message":{"content":"first"}}` + "\n")
	for b.Len() < 300*1024 {
		b.WriteString(`{"type":"assistant","message":{"content":[{"type":"text","text":"filler filler filler"}]}}` + "\n")
	}
	b.WriteString(`{"type":"user","message":{"content":"last one"}}` + "\n")
	write(t, filepath.Join(dir, "p", "m.jsonl"), b.String(), time.Now())
	got := Claude(dir, time.Time{})
	if len(got) != 1 || got[0].Title != "last one" || got[0].CWD != "/w/mid" {
		t.Fatalf("got %+v", got)
	}
}

func TestLargeFileReadsTail(t *testing.T) {
	dir := t.TempDir()
	var b strings.Builder
	b.WriteString(`{"type":"user","cwd":"/w/big","timestamp":"2026-01-02T03:04:05Z","message":{"content":"early"}}` + "\n")
	line := `{"type":"assistant","message":{"content":[{"type":"text","text":"` + strings.Repeat("x", 900) + `"}]}}` + "\n"
	for b.Len() < 10*1024*1024 {
		b.WriteString(line)
	}
	b.WriteString(`{"type":"user","message":{"content":"tail prompt"}}` + "\n")
	b.WriteString(`{"type":"assistant","mess`) // truncated trailing line
	write(t, filepath.Join(dir, "p", "big.jsonl"), b.String(), time.Now())
	start := time.Now()
	got := Claude(dir, time.Time{})
	if d := time.Since(start); d > 200*time.Millisecond {
		t.Fatalf("took %v", d)
	}
	if len(got) != 1 || got[0].Title != "tail prompt" || got[0].CWD != "/w/big" {
		t.Fatalf("got %+v", got)
	}
}

// Codex's session_meta line can carry the full base instructions and exceed
// the 64 KB head window; it must still be read.
func TestCodexHugeSessionMeta(t *testing.T) {
	for _, total := range []int{0, 1 << 20} { // small and windowed files
		dir := t.TempDir()
		var b strings.Builder
		b.WriteString(`{"timestamp":"2026-01-02T03:04:05Z","type":"session_meta","payload":{"id":"cx-big","cwd":"/work/huge","instructions":"` +
			strings.Repeat("i", 200<<10) + `"}}` + "\n")
		filler := `{"timestamp":"2026-01-02T03:04:06Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"` + strings.Repeat("f", 500) + `"}]}}` + "\n"
		for b.Len() < total {
			b.WriteString(filler)
		}
		b.WriteString(`{"timestamp":"2026-01-02T03:05:00Z","type":"event_msg","payload":{"type":"user_message","message":"huge meta prompt"}}` + "\n")
		write(t, filepath.Join(dir, "2026", "01", "02", "rollout-x.jsonl"), b.String(), time.Now())
		got := Codex(dir, time.Time{})
		if len(got) != 1 || got[0].SessionID != "cx-big" || got[0].CWD != "/work/huge" || got[0].Title != "huge meta prompt" {
			t.Fatalf("total=%d: got %+v", total, got)
		}
	}
}

// A first line over the 4 MB bound is not read whole; nothing breaks.
func TestFirstLineBounded(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "x.jsonl")
	write(t, p, strings.Repeat("a", maxFirstLine+10)+"\n"+`{"k":1}`+"\n", time.Now())
	for _, l := range readLines(p) {
		if len(l) > maxFirstLine {
			t.Fatalf("line of %d bytes returned", len(l))
		}
	}
}
