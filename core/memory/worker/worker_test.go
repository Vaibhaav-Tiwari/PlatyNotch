package worker

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/loops"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

var t0 = time.Date(2026, 10, 23, 9, 0, 0, 0, time.UTC)

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time  { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) set(t time.Time) { c.mu.Lock(); c.t = t; c.mu.Unlock() }

type fakeEmb struct {
	clk   *clock
	mu    sync.Mutex
	calls []time.Time
	sizes []int
	err   error
	hook  func(ctx context.Context) error // runs inside Embed; non-nil error is returned
}

func (f *fakeEmb) Name() string  { return "fake" }
func (f *fakeEmb) Model() string { return "fake-model" }
func (f *fakeEmb) Embed(ctx context.Context, texts []string) ([][]float32, error) {
	f.mu.Lock()
	f.calls = append(f.calls, f.clk.now())
	f.sizes = append(f.sizes, len(texts))
	f.mu.Unlock()
	if f.hook != nil {
		if err := f.hook(ctx); err != nil {
			return nil, err
		}
	}
	if f.err != nil {
		return nil, f.err
	}
	out := make([][]float32, len(texts))
	for i := range out {
		out[i] = []float32{1, 0, 0}
	}
	return out, nil
}
func (f *fakeEmb) nCalls() int { f.mu.Lock(); defer f.mu.Unlock(); return len(f.calls) }

type fakeExt struct {
	mu   sync.Mutex
	reqs []provider.ExtractRequest
	res  provider.ExtractResult
	err  error
	hook func()
}

func (f *fakeExt) Name() string { return "fake" }
func (f *fakeExt) Extract(_ context.Context, r provider.ExtractRequest) (provider.ExtractResult, error) {
	f.mu.Lock()
	f.reqs = append(f.reqs, r)
	f.mu.Unlock()
	if f.hook != nil {
		f.hook()
	}
	return f.res, f.err
}
func (f *fakeExt) requests() []provider.ExtractRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]provider.ExtractRequest(nil), f.reqs...)
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

func thread(t *testing.T, s *store.Store, title string) store.Thread {
	t.Helper()
	seq++
	th, err := s.UpsertThread(store.Thread{AppBundle: "com.apple.mail", AppName: "Mail", Key: fmt.Sprint("k", seq), Title: title})
	if err != nil {
		t.Fatal(err)
	}
	return th
}

func chunk(t *testing.T, s *store.Store, th store.Thread, text string, at time.Time) int64 {
	t.Helper()
	seq++
	vid := fmt.Sprint("v", seq)
	if _, err := s.PutVersion(store.Version{ID: vid, ThreadID: th.ID, HourBucket: int64(seq), Content: text, CreatedAt: at}); err != nil {
		t.Fatal(err)
	}
	ids, err := s.AddChunks([]store.Chunk{{VersionID: vid, ThreadID: th.ID, Text: text, CapturedAt: at}})
	if err != nil {
		t.Fatal(err)
	}
	return ids[0]
}

func status(t *testing.T, s *store.Store, id int64) (embed, extract string) {
	t.Helper()
	e, x, err := s.ChunkStatus(id)
	if err != nil {
		t.Fatal(err)
	}
	return e, x
}

func TestEmbedsPending(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0}
	th := thread(t, s, "Inbox")
	for i := 0; i < 70; i++ {
		chunk(t, s, th, fmt.Sprint("text ", i), t0)
	}
	emb := &fakeEmb{clk: clk}
	w := New(s, emb, nil, clk.now)
	w.tick(context.Background())
	if p, _ := s.PendingChunks("embed", 100); len(p) != 6 {
		t.Fatalf("after first tick pending=%d want 6 (batch of 64)", len(p))
	}
	w.tick(context.Background())
	if p, _ := s.PendingChunks("embed", 100); len(p) != 0 {
		t.Fatalf("after second tick pending=%d", len(p))
	}
	if emb.sizes[0] != 64 || emb.sizes[1] != 6 {
		t.Fatalf("batch sizes=%v", emb.sizes)
	}
	n := 0
	s.VisitVectors("fake-model", store.Filter{}, 1000, func(int64, []float32) { n++ })
	if n != 70 {
		t.Fatalf("vectors=%d", n)
	}
	if w.LastError() != "" {
		t.Fatalf("LastError=%q", w.LastError())
	}
}

func TestProviderErrorRetriesWithBackoff(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0}
	id := chunk(t, s, thread(t, s, "Inbox"), "hello", t0)
	emb := &fakeEmb{clk: clk, err: errors.New("boom: connection refused")}
	w := New(s, emb, nil, clk.now)
	steps := []struct {
		at    time.Duration
		calls int
	}{
		{0, 1},
		{59 * time.Second, 1},
		{time.Minute, 2},
		{time.Minute + 4*time.Minute + 59*time.Second, 2},
		{6 * time.Minute, 3},
		{36*time.Minute - time.Second, 3},
		{36 * time.Minute, 4},
		{2*time.Hour + 36*time.Minute - time.Second, 4},
		{2*time.Hour + 36*time.Minute, 5},
		{10 * time.Hour, 5},
	}
	for _, st := range steps {
		clk.set(t0.Add(st.at))
		w.tick(context.Background())
		if got := emb.nCalls(); got != st.calls {
			t.Fatalf("at +%v calls=%d want %d", st.at, got, st.calls)
		}
		if st.calls < 5 {
			if e, _ := status(t, s, id); e != "pending" {
				t.Fatalf("at +%v embed_status=%q", st.at, e)
			}
		}
	}
	if e, _ := status(t, s, id); e != "failed" {
		t.Fatalf("embed_status=%q want failed", e)
	}
	if !strings.Contains(w.LastError(), "boom") {
		t.Fatalf("LastError=%q", w.LastError())
	}
}

func TestSuccessClearsLastError(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0}
	id := chunk(t, s, thread(t, s, "Inbox"), "hello", t0)
	emb := &fakeEmb{clk: clk, err: errors.New("boom")}
	w := New(s, emb, nil, clk.now)
	w.tick(context.Background())
	if w.LastError() == "" {
		t.Fatal("LastError not set")
	}
	emb.mu.Lock()
	emb.err = nil
	emb.mu.Unlock()
	clk.set(t0.Add(time.Minute))
	w.tick(context.Background())
	if e, _ := status(t, s, id); e != "done" || w.LastError() != "" {
		t.Fatalf("status=%q LastError=%q", e, w.LastError())
	}
	if n, err := s.RetryCount(); err != nil || n != 0 {
		t.Fatalf("retry rows left after success: %d %v", n, err)
	}
}

func TestNilProvidersSkip(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0}
	id := chunk(t, s, thread(t, s, "Inbox"), "hello", t0)
	w := New(s, nil, nil, clk.now)
	w.tick(context.Background())
	if e, x := status(t, s, id); e != "skipped" || x != "skipped" {
		t.Fatalf("embed=%q extract=%q", e, x)
	}
}

func TestExtractWaitsForQuietThread(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0}
	th := thread(t, s, "Budget with Priya")
	a := chunk(t, s, th, "I'll send the proposal to Priya tomorrow.", t0)
	b := chunk(t, s, th, "Also need to book flights.", t0.Add(time.Minute))
	// 60 open loops already exist; only 50 go to the extractor.
	for i := 0; i < 60; i++ {
		l := protocol.Loop{Title: fmt.Sprint("Existing loop ", i), Kind: "task", Status: "open", DetectedAt: t0.Add(-time.Hour)}
		if _, err := loops.Apply(s, provider.ExtractResult{Loops: []protocol.Loop{l}}, "Mail", th.ID, t0.Add(-time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	ext := &fakeExt{res: provider.ExtractResult{Loops: []protocol.Loop{{Title: "Send the proposal to Priya", Kind: "commitment", Status: "open", DetectedAt: t0.Add(3 * time.Minute)}}}}
	w := New(s, nil, ext, clk.now)

	clk.set(t0.Add(2 * time.Minute)) // last chunk only 1 min old
	w.tick(context.Background())
	if n := len(ext.requests()); n != 0 {
		t.Fatalf("extracted before thread was quiet: %d calls", n)
	}
	if _, x := status(t, s, a); x != "pending" {
		t.Fatalf("extract_status=%q", x)
	}

	clk.set(t0.Add(3 * time.Minute))
	w.tick(context.Background())
	reqs := ext.requests()
	if len(reqs) != 1 {
		t.Fatalf("calls=%d", len(reqs))
	}
	r := reqs[0]
	if r.App != "Mail" || r.Thread != "Budget with Priya" || !r.Now.Equal(t0.Add(3*time.Minute)) {
		t.Fatalf("req=%+v", r)
	}
	if !strings.Contains(r.Text, "proposal to Priya") || !strings.Contains(r.Text, "book flights") ||
		strings.Index(r.Text, "proposal") > strings.Index(r.Text, "flights") {
		t.Fatalf("text=%q", r.Text)
	}
	if len(r.OpenLoops) != 50 {
		t.Fatalf("open loops sent=%d want 50", len(r.OpenLoops))
	}
	for _, id := range []int64{a, b} {
		if _, x := status(t, s, id); x != "done" {
			t.Fatalf("chunk %d extract_status=%q", id, x)
		}
	}
	open, _ := loops.List(s, "open")
	found := false
	for _, l := range open {
		if l.Title == "Send the proposal to Priya" {
			found = l.SourceApp == "Mail" && l.SourceThread == th.ID
		}
	}
	if !found || len(open) != 61 {
		t.Fatalf("new loop not stored correctly (open=%d)", len(open))
	}
	w.tick(context.Background())
	if n := len(ext.requests()); n != 1 {
		t.Fatalf("re-extracted done chunks: calls=%d", n)
	}
}

func TestExtractBatchCapsChars(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0.Add(time.Hour)}
	th := thread(t, s, "Long")
	for i := 0; i < 10; i++ {
		chunk(t, s, th, strings.Repeat(string(rune('a'+i)), 1000), t0)
	}
	ext := &fakeExt{}
	w := New(s, nil, ext, clk.now)
	w.tick(context.Background())
	w.tick(context.Background())
	w.tick(context.Background())
	reqs := ext.requests()
	if len(reqs) != 2 {
		t.Fatalf("calls=%d want 2", len(reqs))
	}
	if n := len([]rune(reqs[0].Text)); n > 8000 || !strings.Contains(reqs[0].Text, strings.Repeat("g", 1000)) || strings.Contains(reqs[0].Text, "h") {
		t.Fatalf("first batch len=%d", n)
	}
	if !strings.Contains(reqs[1].Text, strings.Repeat("j", 1000)) {
		t.Fatal("second batch missing tail")
	}
}

func TestExtractErrorRetries(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0.Add(time.Hour)}
	id := chunk(t, s, thread(t, s, "Inbox"), "hello", t0)
	ext := &fakeExt{err: errors.New("extract down")}
	w := New(s, nil, ext, clk.now)
	w.tick(context.Background())
	w.tick(context.Background())
	if n := len(ext.requests()); n != 1 {
		t.Fatalf("calls=%d want 1 before backoff elapses", n)
	}
	if _, x := status(t, s, id); x != "pending" || !strings.Contains(w.LastError(), "extract down") {
		t.Fatalf("status=%q LastError=%q", x, w.LastError())
	}
	clk.set(t0.Add(time.Hour + time.Minute))
	w.tick(context.Background())
	if n := len(ext.requests()); n != 2 {
		t.Fatalf("calls=%d want 2 after 1 min", n)
	}
}

func TestOnLoopsChangedFires(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0.Add(time.Hour)}
	chunk(t, s, thread(t, s, "Inbox"), "I'll call the bank.", t0)
	ext := &fakeExt{res: provider.ExtractResult{Loops: []protocol.Loop{{Title: "Call the bank", Kind: "commitment", Status: "open", DetectedAt: t0}}}}
	w := New(s, nil, ext, clk.now)
	var mu sync.Mutex
	var got [][]protocol.Loop
	for i := 0; i < 2; i++ {
		w.OnLoopsChanged(func(ls []protocol.Loop) {
			_ = w.LastError() // must not deadlock: callbacks run outside the lock
			mu.Lock()
			got = append(got, ls)
			mu.Unlock()
		})
	}
	w.tick(context.Background())
	mu.Lock()
	if len(got) != 2 || len(got[0]) != 1 || got[0][0].Title != "Call the bank" || got[0][0].Status != "open" {
		t.Fatalf("got=%+v", got)
	}
	mu.Unlock()
	// Same loop again from new text: nothing changes, no callback.
	chunk(t, s, thread(t, s, "Other"), "call the bank!", t0)
	w.tick(context.Background())
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 2 {
		t.Fatalf("callback fired without a change: %d", len(got))
	}
}

func TestArchiveStaleFromWorker(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0.Add(15 * 24 * time.Hour)}
	loops.Apply(s, provider.ExtractResult{Loops: []protocol.Loop{{Title: "Old", Kind: "task", Status: "open", DetectedAt: t0}}}, "Mail", "th", t0)
	w := New(s, nil, nil, clk.now)
	var fired []protocol.Loop
	called := false
	w.OnLoopsChanged(func(ls []protocol.Loop) { called, fired = true, ls })
	w.tick(context.Background())
	if st, _ := loops.List(s, "stale"); len(st) != 1 || !called || len(fired) != 0 {
		t.Fatalf("stale=%d called=%v open=%d", len(st), called, len(fired))
	}
}

func TestPurgedMidFlightSkipped(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0.Add(time.Hour)}
	chunk(t, s, thread(t, s, "Inbox"), "I'll call the bank.", t0)
	purge := func() {
		if _, err := s.PurgeBefore(t0.Add(24 * time.Hour)); err != nil {
			t.Error(err)
		}
	}
	emb := &fakeEmb{clk: clk, hook: func(context.Context) error { purge(); return nil }}
	w := New(s, emb, nil, clk.now)
	w.tick(context.Background())
	if w.LastError() != "" || emb.nCalls() != 1 {
		t.Fatalf("embed: LastError=%q calls=%d", w.LastError(), emb.nCalls())
	}

	chunk(t, s, thread(t, s, "Inbox2"), "I'll call the bank.", t0)
	ext := &fakeExt{res: provider.ExtractResult{Loops: []protocol.Loop{{Title: "Call the bank", Kind: "task", Status: "open", DetectedAt: t0}}}, hook: purge}
	w = New(s, nil, ext, clk.now)
	w.tick(context.Background())
	if w.LastError() != "" || len(ext.requests()) != 1 {
		t.Fatalf("extract: LastError=%q calls=%d", w.LastError(), len(ext.requests()))
	}
	if all, _ := loops.List(s, ""); len(all) != 0 {
		t.Fatalf("loops from purged thread stored: %+v", all)
	}
}

func TestRunStopsOnCancel(t *testing.T) {
	s := openStore(t)
	clk := &clock{t: t0}
	id := chunk(t, s, thread(t, s, "Inbox"), "hello", t0)
	started := make(chan struct{})
	var once sync.Once
	emb := &fakeEmb{clk: clk, hook: func(ctx context.Context) error {
		once.Do(func() { close(started) })
		<-ctx.Done()
		return ctx.Err()
	}}
	w := New(s, emb, nil, clk.now)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { w.Run(ctx); close(done) }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not tick immediately")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not stop after cancel")
	}
	if e, _ := status(t, s, id); e != "pending" || w.LastError() != "" {
		t.Fatalf("cancellation counted as failure: status=%q LastError=%q", e, w.LastError())
	}
	if n, err := s.RetryCount(); err != nil || n != 0 {
		t.Fatalf("retry rows=%d err=%v", n, err)
	}
}
