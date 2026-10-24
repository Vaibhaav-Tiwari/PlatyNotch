package engine

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

var t0 = time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC)

func TestEngineImplementsService(t *testing.T) {
	var _ memory.Service = (*Engine)(nil)
}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }
func newClock(t time.Time) *clock    { return &clock{t: t} }
func memCfg(emb, ext string) config.Memory {
	return config.Memory{Enabled: true, RetentionDays: 90,
		Embedder: config.Provider{Name: emb, Model: "m1"}, Extractor: config.Provider{Name: ext, Model: "x1"}}
}

// fakeEmb embeds every text as the same unit vector and records the texts.
type fakeEmb struct {
	mu    sync.Mutex
	texts []string
}

func (f *fakeEmb) Name() string  { return "enginetest-emb" }
func (f *fakeEmb) Model() string { return "m1" }
func (f *fakeEmb) Embed(_ context.Context, texts []string) ([][]float32, error) {
	f.mu.Lock()
	f.texts = append(f.texts, texts...)
	f.mu.Unlock()
	out := make([][]float32, len(texts))
	for i := range out {
		out[i] = []float32{1, 0, 0}
	}
	return out, nil
}
func (f *fakeEmb) saw(s string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, t := range f.texts {
		if strings.Contains(t, s) {
			return true
		}
	}
	return false
}

// fakeExt turns every text containing "I will" into one open loop.
type fakeExt struct {
	mu    sync.Mutex
	calls int
}

func (f *fakeExt) Name() string { return "enginetest-ext" }
func (f *fakeExt) Extract(_ context.Context, r provider.ExtractRequest) (provider.ExtractResult, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()
	if !strings.Contains(r.Text, "I will") {
		return provider.ExtractResult{}, nil
	}
	return provider.ExtractResult{Loops: []protocol.Loop{{Title: "Send the quarterly report", Kind: "commitment", Quote: "I will send the report"}}}, nil
}
func (f *fakeExt) n() int { f.mu.Lock(); defer f.mu.Unlock(); return f.calls }

var (
	emb = &fakeEmb{}
	ext = &fakeExt{}
)

func init() {
	provider.RegisterEmbedder("enginetest-emb", func(config.Provider) (provider.Embedder, error) { return emb, nil })
	provider.RegisterExtractor("enginetest-ext", func(config.Provider) (provider.Extractor, error) { return ext, nil })
}

// openTest opens an engine on a temp db driven by clk and a manual tick channel.
func openTest(t *testing.T, path string, cfg config.Memory, clk *clock) (*Engine, chan time.Time) {
	t.Helper()
	tick := make(chan time.Time)
	e, err := open(path, cfg, clk.now, tick)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { e.Close() })
	return e, tick
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

const mailText = "Hi Sam, about the Lisbon offsite budget: I will send the report by Friday afternoon."

func capture(at time.Time) protocol.CaptureText {
	return protocol.CaptureText{AppBundle: "com.apple.mail", AppName: "Mail", WindowTitle: "Offsite", Text: mailText, CapturedAt: at}
}

func TestIngestThenSearch(t *testing.T) {
	e, _ := openTest(t, filepath.Join(t.TempDir(), "m.db"), memCfg("none", "none"), newClock(t0))
	ctx := context.Background()
	if err := e.Ingest(ctx, capture(t0)); err != nil {
		t.Fatal(err)
	}
	hits, err := e.Search(ctx, protocol.MemorySearch{Query: "lisbon budget"})
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 || !strings.Contains(hits[0].Snippet, "Lisbon") || hits[0].SourceApp != "Mail" {
		t.Fatalf("hits: %+v", hits)
	}
}

// TestGraphUsesTheEngineClock: the window is measured from the engine's now.
func TestGraphUsesTheEngineClock(t *testing.T) {
	clk := newClock(t0)
	e, _ := openTest(t, filepath.Join(t.TempDir(), "m.db"), memCfg("none", "none"), clk)
	ctx := context.Background()
	if err := e.Ingest(ctx, capture(t0)); err != nil {
		t.Fatal(err)
	}
	g, err := e.Graph(ctx, protocol.MemoryGraphQuery{Hours: 24})
	if err != nil || len(g.Nodes) != 2 || len(g.Edges) != 1 {
		t.Fatalf("graph %+v %v", g, err)
	}
	clk.add(48 * time.Hour)
	if g, err := e.Graph(ctx, protocol.MemoryGraphQuery{Hours: 24}); err != nil || len(g.Nodes) != 0 {
		t.Fatalf("two days later: %+v %v", g, err)
	}
	e.Close()
	if _, err := e.Graph(ctx, protocol.MemoryGraphQuery{}); err == nil {
		t.Fatal("Graph after Close succeeded")
	}
}

func TestStatusCounts(t *testing.T) {
	e, _ := openTest(t, filepath.Join(t.TempDir(), "m.db"), memCfg("none", "none"), newClock(t0))
	if err := e.Ingest(context.Background(), capture(t0)); err != nil {
		t.Fatal(err)
	}
	// With no providers the worker marks the new chunk skipped, so nothing stays pending.
	eventually(t, "chunk skipped", func() bool { return e.Status().Pending == 0 })
	st := e.Status()
	want := protocol.MemoryStatus{Enabled: true, Threads: 1, Versions: 1, Chunks: 1, Embedder: "none", Extractor: "none"}
	if st != want {
		t.Fatalf("status\n got %+v\nwant %+v", st, want)
	}

	e2, _ := openTest(t, filepath.Join(t.TempDir(), "m.db"), memCfg("enginetest-emb", "enginetest-ext"), newClock(t0))
	if st := e2.Status(); st.Embedder != "enginetest-emb/m1" || st.Extractor != "enginetest-ext/x1" {
		t.Fatalf("provider names: %+v", st)
	}
}

func TestBadProviderKeepsMemoryOnAndReportsError(t *testing.T) {
	e, _ := openTest(t, filepath.Join(t.TempDir(), "m.db"), memCfg("no-such-embedder", "none"), newClock(t0))
	st := e.Status()
	if !st.Enabled || st.Embedder != "none" || !strings.Contains(st.LastError, "no-such-embedder") {
		t.Fatalf("status: %+v", st)
	}
}

func TestDisabledReturnsNil(t *testing.T) {
	home := t.TempDir()
	t.Setenv("PLATYNOTCH_HOME", filepath.Join(home, "pn"))
	cfg := config.Default()
	svc, err := OpenFromConfig(cfg)
	if svc != nil || err != nil {
		t.Fatalf("disabled: %v %v", svc, err)
	}
	cfg.Memory.Enabled = true
	svc, err = OpenFromConfig(cfg)
	if err != nil || svc == nil {
		t.Fatalf("enabled: %v %v", svc, err)
	}
	defer svc.Close()
	if _, err := os.Stat(filepath.Join(home, "pn", "memory.db")); err != nil {
		t.Fatalf("memory.db not created in home: %v", err)
	}
	if !svc.Status().Enabled {
		t.Fatal("status not enabled")
	}
}

func TestBackfillSkippedWhenProviderConfigured(t *testing.T) {
	path := filepath.Join(t.TempDir(), "m.db")
	clk := newClock(t0)
	e, _ := openTest(t, path, memCfg("none", "none"), clk)
	if err := e.Ingest(context.Background(), capture(t0.Add(-10*time.Minute))); err != nil {
		t.Fatal(err)
	}
	eventually(t, "chunk skipped", func() bool { return e.Status().Pending == 0 })
	if err := e.Close(); err != nil {
		t.Fatal(err)
	}

	before := ext.n()
	e2, _ := openTest(t, path, memCfg("enginetest-emb", "enginetest-ext"), clk)
	eventually(t, "old chunk embedded", func() bool { return emb.saw("Lisbon offsite") })
	eventually(t, "old chunk extracted", func() bool { return ext.n() > before })
	eventually(t, "nothing pending", func() bool { return e2.Status().Pending == 0 })
	if ls, err := e2.Loops(context.Background(), "open"); err != nil || len(ls) != 1 {
		t.Fatalf("loops after backfill: %v %+v", err, ls)
	}
}

type recorder struct {
	mu    sync.Mutex
	calls [][]protocol.Loop
}

func (r *recorder) fn(ls []protocol.Loop) { r.mu.Lock(); r.calls = append(r.calls, ls); r.mu.Unlock() }
func (r *recorder) n() int                { r.mu.Lock(); defer r.mu.Unlock(); return len(r.calls) }
func (r *recorder) last() []protocol.Loop {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.calls[len(r.calls)-1]
}

func TestLoopsChangedFromWorkerAndSetStatus(t *testing.T) {
	clk := newClock(t0)
	e, _ := openTest(t, filepath.Join(t.TempDir(), "m.db"), memCfg("none", "enginetest-ext"), clk)
	var r recorder
	e.OnLoopsChanged(r.fn)
	ctx := context.Background()
	// Captured 10 minutes ago, so the thread is already quiet; Ingest wakes the worker.
	if err := e.Ingest(ctx, capture(t0.Add(-10*time.Minute))); err != nil {
		t.Fatal(err)
	}
	eventually(t, "worker loop notification", func() bool { return r.n() >= 1 })
	ls := r.last()
	if len(ls) != 1 || ls[0].Title != "Send the quarterly report" || ls[0].Status != "open" {
		t.Fatalf("loops: %+v", ls)
	}

	n := r.n()
	if err := e.SetLoopStatus(ctx, protocol.LoopSetStatus{ID: ls[0].ID, Status: "dismissed"}); err != nil {
		t.Fatal(err)
	}
	if r.n() != n+1 || len(r.last()) != 0 {
		t.Fatalf("after dismiss: %d calls, last %+v", r.n(), r.last())
	}
	if err := e.SetLoopStatus(ctx, protocol.LoopSetStatus{ID: ls[0].ID, Status: "bogus"}); err == nil {
		t.Fatal("bogus status accepted")
	}
	if r.n() != n+1 {
		t.Fatal("failed SetLoopStatus notified subscribers")
	}
}

func TestRetentionPurgeDaily(t *testing.T) {
	clk := newClock(t0)
	cfg := memCfg("none", "none")
	cfg.RetentionDays = 2
	e, tick := openTest(t, filepath.Join(t.TempDir(), "m.db"), cfg, clk)
	if err := e.Ingest(context.Background(), capture(t0.Add(-time.Hour))); err != nil {
		t.Fatal(err)
	}
	eventually(t, "chunk stored", func() bool { return e.Status().Chunks == 1 })

	clk.add(36 * time.Hour) // within retention, and the daily purge already ran at open
	tick <- clk.now()
	tick <- clk.now() // the second send returns once the first tick was handled
	if c := e.Status().Chunks; c != 1 {
		t.Fatalf("chunk purged early: %d", c)
	}
	clk.add(25 * time.Hour) // capture now 62h old, last purge 25h ago
	tick <- clk.now()
	tick <- clk.now()
	if c := e.Status().Chunks; c != 0 {
		t.Fatalf("chunk not purged: %d", c)
	}
}

func TestPurgeOnOpen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "m.db")
	clk := newClock(t0)
	cfg := memCfg("none", "none")
	cfg.RetentionDays = 1
	e, _ := openTest(t, path, cfg, clk)
	if err := e.Ingest(context.Background(), capture(t0.Add(-48*time.Hour))); err != nil {
		t.Fatal(err)
	}
	e.Close()
	e2, _ := openTest(t, path, cfg, clk)
	if c := e2.Status().Chunks; c != 0 {
		t.Fatalf("old chunk survived open: %d", c)
	}
}

func TestArchiveStaleHourly(t *testing.T) {
	clk := newClock(t0)
	e, tick := openTest(t, filepath.Join(t.TempDir(), "m.db"), memCfg("none", "enginetest-ext"), clk)
	var r recorder
	e.OnLoopsChanged(r.fn)
	if err := e.Ingest(context.Background(), capture(t0.Add(-10*time.Minute))); err != nil {
		t.Fatal(err)
	}
	eventually(t, "loop extracted", func() bool { return r.n() >= 1 && len(r.last()) == 1 })

	clk.add(15 * 24 * time.Hour)
	tick <- clk.now()
	tick <- clk.now()
	if len(r.last()) != 0 {
		t.Fatalf("open loops after 15 days: %+v", r.last())
	}
	if st, err := e.Loops(context.Background(), "stale"); err != nil || len(st) != 1 {
		t.Fatalf("stale loops: %v %+v", err, st)
	}
}

func TestCloseTwice(t *testing.T) {
	e, _ := openTest(t, filepath.Join(t.TempDir(), "m.db"), memCfg("none", "none"), newClock(t0))
	if err := e.Close(); err != nil {
		t.Fatal(err)
	}
	if err := e.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if err := e.Ingest(context.Background(), capture(t0)); err == nil {
		t.Fatal("Ingest after Close succeeded")
	}
}

// TestOpenRequeuesFailedAndStaleModel: on Open with providers, chunks that
// failed (e.g. during a provider outage) and chunks embedded by a different
// model go back to pending and are processed again.
func TestOpenRequeuesFailedAndStaleModel(t *testing.T) {
	path := filepath.Join(t.TempDir(), "m.db")
	s, err := store.Open(path, false)
	if err != nil {
		t.Fatal(err)
	}
	th, _ := s.UpsertThread(store.Thread{AppBundle: "a", Key: "k"})
	if _, err := s.PutVersion(store.Version{ID: "v", ThreadID: th.ID, HourBucket: t0.Unix() / 3600, Content: "x", CreatedAt: t0}); err != nil {
		t.Fatal(err)
	}
	ids, err := s.AddChunks([]store.Chunk{
		{VersionID: "v", ThreadID: th.ID, Idx: 0, Text: "staleModelChunk alpha", CapturedAt: t0},
		{VersionID: "v", ThreadID: th.ID, Idx: 1, Text: "failedEmbedChunk beta", CapturedAt: t0},
		{VersionID: "v", ThreadID: th.ID, Idx: 2, Text: "failedExtractChunk I will call Dana", CapturedAt: t0},
		{VersionID: "v", ThreadID: th.ID, Idx: 3, Text: "currentModelChunk gamma", CapturedAt: t0},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetVector(ids[0], "old-model", []float32{1, 0, 0}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetVector(ids[2], "m1", []float32{1, 0, 0}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetVector(ids[3], "m1", []float32{1, 0, 0}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetChunkStatus("embed", ids[1:2], "failed"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetChunkStatus("extract", []int64{ids[0], ids[1], ids[3]}, "done"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetChunkStatus("extract", ids[2:3], "failed"); err != nil {
		t.Fatal(err)
	}
	s.Close()

	before := ext.n()
	e, _ := openTest(t, path, memCfg("enginetest-emb", "enginetest-ext"), newClock(t0.Add(time.Hour)))
	eventually(t, "stale-model chunk re-embedded", func() bool { return emb.saw("staleModelChunk") })
	eventually(t, "failed chunk re-embedded", func() bool { return emb.saw("failedEmbedChunk") })
	eventually(t, "failed extract retried", func() bool { return ext.n() > before })
	eventually(t, "nothing pending", func() bool { return e.Status().Pending == 0 })
	if emb.saw("currentModelChunk") {
		t.Fatal("chunk already embedded by the current model was re-embedded")
	}
}
