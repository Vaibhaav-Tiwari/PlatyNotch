package search

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"path/filepath"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

type fakeEmb struct {
	model string
	vec   []float32
	err   error
}

func (f fakeEmb) Name() string  { return "fake" }
func (f fakeEmb) Model() string { return f.model }
func (f fakeEmb) Embed(_ context.Context, texts []string) ([][]float32, error) {
	if f.err != nil {
		return nil, f.err
	}
	out := make([][]float32, len(texts))
	for i := range out {
		out[i] = f.vec
	}
	return out, nil
}

func openStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "m.db"), false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

var seq int

// add creates a thread (unique per call) with one chunk; vec/model optional.
func add(t *testing.T, s *store.Store, bundle, name, text string, at time.Time, model string, vec []float32) int64 {
	t.Helper()
	seq++
	th, err := s.UpsertThread(store.Thread{AppBundle: bundle, AppName: name, Key: fmt.Sprint("k", seq), Title: fmt.Sprint("T", seq)})
	if err != nil {
		t.Fatal(err)
	}
	vid := fmt.Sprint("v", seq)
	if _, err := s.PutVersion(store.Version{ID: vid, ThreadID: th.ID, HourBucket: int64(seq), Content: text, ContentHash: vid, Chars: len(text), CreatedAt: at}); err != nil {
		t.Fatal(err)
	}
	ids, err := s.AddChunks([]store.Chunk{{VersionID: vid, ThreadID: th.ID, Text: text, CapturedAt: at}})
	if err != nil {
		t.Fatal(err)
	}
	if vec != nil {
		if err := s.SetVector(ids[0], model, vec); err != nil {
			t.Fatal(err)
		}
	}
	return ids[0]
}

func TestKeywordOnly(t *testing.T) {
	s := openStore(t)
	now := time.Now()
	add(t, s, "com.a", "A", "the quarterly budget review is tomorrow", now, "", nil)
	add(t, s, "com.a", "A", "lunch plans", now, "", nil)
	hits, err := Search(context.Background(), s, nil, protocol.MemorySearch{Query: "budget"})
	if err != nil || len(hits) != 1 {
		t.Fatalf("hits=%v err=%v", hits, err)
	}
	if hits[0].SourceApp != "A" || hits[0].Snippet == "" || hits[0].Score <= 0 {
		t.Fatalf("bad hit %+v", hits[0])
	}
}

func TestFusionPrefersBoth(t *testing.T) {
	s := openStore(t)
	now := time.Now()
	q := []float32{1, 0}
	add(t, s, "b", "B", "alpha", now, "m", []float32{0, 1})                                    // kw #1, vec far
	a := add(t, s, "a", "A", "alpha with some extra words here", now, "m", []float32{1, 0.01}) // kw #2, vec #1
	add(t, s, "c", "C", "unrelated", now, "m", []float32{1, 0.2})                              // vec only
	hits, err := Search(context.Background(), s, fakeEmb{model: "m", vec: q}, protocol.MemorySearch{Query: "alpha"})
	if err != nil || len(hits) != 3 {
		t.Fatalf("hits=%v err=%v", hits, err)
	}
	rows, _ := s.ChunksByIDs([]int64{a})
	if hits[0].ThreadID != rows[0].ThreadID {
		t.Fatalf("expected both-list chunk first, got %+v", hits)
	}
}

func TestModelMismatchIgnored(t *testing.T) {
	s := openStore(t)
	now := time.Now()
	add(t, s, "c", "C", "unrelated", now, "old", []float32{1, 0})
	hits, err := Search(context.Background(), s, fakeEmb{model: "new", vec: []float32{1, 0}}, protocol.MemorySearch{Query: "alpha"})
	if err != nil || len(hits) != 0 {
		t.Fatalf("hits=%v err=%v", hits, err)
	}
	// dimension mismatch is skipped too
	add(t, s, "d", "D", "other", now, "new", []float32{1, 0, 0})
	hits, err = Search(context.Background(), s, fakeEmb{model: "new", vec: []float32{1, 0}}, protocol.MemorySearch{Query: "alpha"})
	if err != nil || len(hits) != 0 {
		t.Fatalf("dim mismatch used: hits=%v err=%v", hits, err)
	}
}

func TestFilters(t *testing.T) {
	s := openStore(t)
	base := time.Date(2026, 5, 10, 12, 0, 0, 0, time.UTC)
	add(t, s, "com.apple.mail", "Mail", "report draft", base, "", nil)
	add(t, s, "com.slack", "Slack", "report thread", base.Add(48*time.Hour), "", nil)
	ctx := context.Background()
	since := base.Add(24 * time.Hour)
	until := base.Add(24 * time.Hour)
	if h, _ := Search(ctx, s, nil, protocol.MemorySearch{Query: "report", Since: &since}); len(h) != 1 || h[0].SourceApp != "Slack" {
		t.Fatalf("since: %+v", h)
	}
	if h, _ := Search(ctx, s, nil, protocol.MemorySearch{Query: "report", Until: &until}); len(h) != 1 || h[0].SourceApp != "Mail" {
		t.Fatalf("until: %+v", h)
	}
	if h, _ := Search(ctx, s, nil, protocol.MemorySearch{Query: "report", App: "COM.SLACK"}); len(h) != 1 || h[0].SourceApp != "Slack" {
		t.Fatalf("app bundle: %+v", h)
	}
	if h, _ := Search(ctx, s, nil, protocol.MemorySearch{Query: "report", App: "mail"}); len(h) != 1 || h[0].SourceApp != "Mail" {
		t.Fatalf("app name: %+v", h)
	}
}

func TestPunctuationQuery(t *testing.T) {
	s := openStore(t)
	add(t, s, "a", "A", "what's up with x", time.Now(), "", nil)
	for _, q := range []string{`what's "up"? (x)`, `"`, `* AND OR NEAR(`, `?!`} {
		if _, err := Search(context.Background(), s, nil, protocol.MemorySearch{Query: q}); err != nil {
			t.Fatalf("%q: %v", q, err)
		}
	}
}

func TestEmptyQueryRecency(t *testing.T) {
	s := openStore(t)
	now := time.Now()
	add(t, s, "a", "A", "old thing", now.Add(-time.Hour), "", nil)
	add(t, s, "a", "A", "new thing", now, "", nil)
	hits, err := Search(context.Background(), s, nil, protocol.MemorySearch{Query: "   "})
	if err != nil || len(hits) != 2 || hits[0].Snippet != "new thing" {
		t.Fatalf("hits=%v err=%v", hits, err)
	}
}

func TestLimitAndGrouping(t *testing.T) {
	s := openStore(t)
	now := time.Now()
	for i := 0; i < 60; i++ {
		add(t, s, "a", "A", "common word", now.Add(time.Duration(i)*time.Second), "", nil)
	}
	h, _ := Search(context.Background(), s, nil, protocol.MemorySearch{Query: "common"})
	if len(h) != 10 {
		t.Fatalf("default limit: %d", len(h))
	}
	h, _ = Search(context.Background(), s, nil, protocol.MemorySearch{Query: "common", Limit: 500})
	if len(h) != 50 {
		t.Fatalf("max limit: %d", len(h))
	}
	// same thread, two chunks -> one hit
	th, _ := s.UpsertThread(store.Thread{AppBundle: "g", AppName: "G", Key: "g", Title: "G"})
	s.PutVersion(store.Version{ID: "vg", ThreadID: th.ID, HourBucket: 999, Content: "x", ContentHash: "x", CreatedAt: now})
	s.AddChunks([]store.Chunk{{VersionID: "vg", ThreadID: th.ID, Idx: 0, Text: "zebra one", CapturedAt: now}, {VersionID: "vg", ThreadID: th.ID, Idx: 1, Text: "zebra two", CapturedAt: now}})
	h, _ = Search(context.Background(), s, nil, protocol.MemorySearch{Query: "zebra"})
	if len(h) != 1 {
		t.Fatalf("grouping: %+v", h)
	}
}

func TestEmbedFailureFallsBack(t *testing.T) {
	s := openStore(t)
	add(t, s, "a", "A", "budget", time.Now(), "", nil)
	h, err := Search(context.Background(), s, fakeEmb{model: "m", err: errors.New("down")}, protocol.MemorySearch{Query: "budget"})
	if err != nil || len(h) != 1 {
		t.Fatalf("h=%v err=%v", h, err)
	}
}

func TestSnippetAroundTerm(t *testing.T) {
	long := ""
	for i := 0; i < 100; i++ {
		long += "filler "
	}
	text := long + "needle " + long
	sn := snippet(text, "needle")
	if n := len([]rune(sn)); n > 300 || !contains(sn, "needle") {
		t.Fatalf("len=%d %q", n, sn)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool { return indexOf(s, sub) >= 0 })()
}
func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func TestCosine(t *testing.T) {
	if c := Cosine([]float32{1, 0}, []float32{1, 0}); c < 0.999 {
		t.Fatal(c)
	}
	if Cosine([]float32{1, 0}, []float32{1}) != 0 || Cosine([]float32{0, 0}, []float32{1, 0}) != 0 {
		t.Fatal("degenerate")
	}
}

func TestPerf20k(t *testing.T) {
	s := openStore(t)
	const n, dim = 20000, 64
	rng := rand.New(rand.NewSource(1))
	now := time.Now()
	th, _ := s.UpsertThread(store.Thread{AppBundle: "p", AppName: "P", Key: "p", Title: "P"})
	s.PutVersion(store.Version{ID: "vp", ThreadID: th.ID, HourBucket: 1, Content: "x", ContentHash: "x", CreatedAt: now})
	cs := make([]store.Chunk, n)
	for i := range cs {
		cs[i] = store.Chunk{VersionID: "vp", ThreadID: th.ID, Idx: i, Text: fmt.Sprintf("synthetic chunk %d about topic%d", i, i%50), CapturedAt: now.Add(-time.Duration(i) * time.Second)}
	}
	ids, err := s.AddChunks(cs)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		v := make([]float32, dim)
		for j := range v {
			v[j] = rng.Float32()
		}
		if err := s.SetVector(id, "m", v); err != nil {
			t.Fatal(err)
		}
	}
	q := make([]float32, dim)
	for j := range q {
		q[j] = rng.Float32()
	}
	e := fakeEmb{model: "m", vec: q}
	start := time.Now()
	h, err := Search(context.Background(), s, e, protocol.MemorySearch{Query: "topic7 synthetic"})
	d := time.Since(start)
	if err != nil || len(h) == 0 {
		t.Fatalf("h=%d err=%v", len(h), err)
	}
	t.Logf("search took %v", d)
	// The race detector slows this CPU-bound loop ~35x; enforce the 300ms
	// budget only on normal builds.
	if !raceEnabled && d > 300*time.Millisecond {
		t.Fatalf("too slow: %v", d)
	}
}
