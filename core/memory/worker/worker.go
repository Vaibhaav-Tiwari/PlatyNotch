// Package worker runs the background memory pipeline: it embeds new chunks
// and, once a thread has gone quiet, asks the extractor for open loops and
// resolutions. Failed provider calls are retried with backoff.
package worker

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/loops"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

const (
	tickEvery       = 10 * time.Second
	providerTimeout = 30 * time.Second
	embedBatch      = 64
	extractQuiet    = 2 * time.Minute
	extractMaxChars = 8000
	extractScan     = 64 // chunks considered for one extract batch
	maxOpenLoops    = 50
	staleAfter      = 14 * 24 * time.Hour
	archiveEvery    = time.Hour
	chunkSep        = "\n\n"
)

// backoff[i] is the wait after failure i+1; a failure past the end marks the
// chunk "failed".
var backoff = []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour}

// Worker processes pending chunks. Run it in a single goroutine.
type Worker struct {
	s   *store.Store
	e   provider.Embedder
	x   provider.Extractor
	now func() time.Time

	mu   sync.Mutex
	errs map[string]string // "embed" / "extract" → last error
	cbs  []func([]protocol.Loop)

	lastArchive time.Time // touched only by the worker goroutine
}

// New builds a worker. e or x may be nil (that kind of work is skipped).
// now defaults to time.Now.
func New(s *store.Store, e provider.Embedder, x provider.Extractor, now func() time.Time) *Worker {
	if now == nil {
		now = time.Now
	}
	return &Worker{s: s, e: e, x: x, now: now, errs: map[string]string{}}
}

// Run processes work immediately and then every 10 s until ctx is done.
func (w *Worker) Run(ctx context.Context) {
	t := time.NewTicker(tickEvery)
	defer t.Stop()
	for {
		w.tick(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// OnLoopsChanged registers fn, called (outside any lock, on the worker
// goroutine) with the current open loops whenever loops change.
func (w *Worker) OnLoopsChanged(fn func([]protocol.Loop)) {
	w.mu.Lock()
	w.cbs = append(w.cbs, fn)
	w.mu.Unlock()
}

// LastError returns the most recent unresolved error, or "".
func (w *Worker) LastError() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	var parts []string
	for _, k := range []string{"embed", "extract", "loops"} {
		if e := w.errs[k]; e != "" {
			parts = append(parts, k+": "+e)
		}
	}
	return strings.Join(parts, "; ")
}

func (w *Worker) setErr(kind string, err error) {
	w.mu.Lock()
	if err == nil {
		delete(w.errs, kind)
	} else {
		w.errs[kind] = err.Error()
	}
	w.mu.Unlock()
}

// tick does at most one embed batch, one extract batch and (hourly) the
// stale-loop sweep.
func (w *Worker) tick(ctx context.Context) {
	if ctx.Err() != nil {
		return
	}
	if err := w.embedOnce(ctx); err != nil && ctx.Err() == nil {
		w.setErr("embed", err)
	}
	if ctx.Err() != nil {
		return
	}
	changed, err := w.extractOnce(ctx)
	if err != nil && ctx.Err() == nil {
		w.setErr("extract", err)
	}
	if ctx.Err() != nil {
		return
	}
	if now := w.now(); w.lastArchive.IsZero() || now.Sub(w.lastArchive) >= archiveEvery {
		n, err := loops.ArchiveStale(w.s, staleAfter, now)
		if err != nil {
			w.setErr("loops", err)
		} else {
			w.lastArchive = now
			changed = changed || n > 0
		}
	}
	if changed {
		w.notify()
	}
}

func (w *Worker) notify() {
	open, err := loops.List(w.s, "open")
	if err != nil {
		w.setErr("loops", err)
		return
	}
	w.setErr("loops", nil)
	w.mu.Lock()
	cbs := slices.Clone(w.cbs)
	w.mu.Unlock()
	for _, fn := range cbs {
		fn(open)
	}
}

func (w *Worker) retryAt(now time.Time) func(int) (time.Time, bool) {
	return func(attempts int) (time.Time, bool) {
		if attempts > len(backoff) {
			return time.Time{}, false
		}
		return now.Add(backoff[attempts-1]), true
	}
}

func ids(cs []store.Chunk) []int64 {
	out := make([]int64, len(cs))
	for i, c := range cs {
		out[i] = c.ID
	}
	return out
}

func (w *Worker) embedOnce(ctx context.Context) error {
	now := w.now()
	// A chunk that already failed in a batch is retried on its own, so one
	// bad chunk cannot keep failing (and eventually fail) its neighbours.
	var cs []store.Chunk
	if w.e != nil {
		c, ok, err := w.s.DueRetryChunk("embed", now)
		if err != nil {
			return err
		}
		if ok {
			cs = []store.Chunk{c}
		}
	}
	if cs == nil {
		var err error
		if cs, err = w.s.DueChunks("embed", "", now, embedBatch); err != nil || len(cs) == 0 {
			return err
		}
	}
	if w.e == nil {
		return w.s.SetChunkStatus("embed", ids(cs), "skipped")
	}
	texts := make([]string, len(cs))
	for i, c := range cs {
		texts[i] = c.Text
	}
	cctx, cancel := context.WithTimeout(ctx, providerTimeout)
	vecs, err := w.e.Embed(cctx, texts)
	cancel()
	if ctx.Err() != nil {
		return ctx.Err() // shutting down: not a provider failure
	}
	if err == nil && len(vecs) != len(cs) {
		err = fmt.Errorf("embedder returned %d vectors for %d texts", len(vecs), len(cs))
	}
	if err != nil {
		w.setErr("embed", err)
		return w.s.FailChunks("embed", ids(cs), err.Error(), w.retryAt(now))
	}
	model := w.e.Model()
	for i, c := range cs {
		if err := w.s.SetVector(c.ID, model, vecs[i]); err != nil && !errors.Is(err, store.ErrChunkGone) {
			return err
		}
	}
	w.setErr("embed", nil)
	return nil
}

func (w *Worker) extractOnce(ctx context.Context) (changed bool, err error) {
	now := w.now()
	if w.x == nil {
		cs, err := w.s.DueChunks("extract", "", now, extractScan)
		if err != nil || len(cs) == 0 {
			return false, err
		}
		return false, w.s.SetChunkStatus("extract", ids(cs), "skipped")
	}
	tid, ok, err := w.s.QuietExtractThread(now.Add(-extractQuiet), now)
	if err != nil || !ok {
		return false, err
	}
	th, ok, err := w.s.GetThread(tid)
	if err != nil || !ok {
		return false, err
	}
	cs, err := w.s.DueChunks("extract", tid, now, extractScan)
	if err != nil || len(cs) == 0 {
		return false, err
	}
	var b strings.Builder
	n := 0
	batch := cs[:0:0]
	for _, c := range cs {
		add := utf8.RuneCountInString(c.Text)
		if len(batch) > 0 {
			add += len(chunkSep)
		}
		if len(batch) > 0 && n+add > extractMaxChars {
			break
		}
		if len(batch) > 0 {
			b.WriteString(chunkSep)
		}
		text := c.Text
		if add > extractMaxChars { // a single oversized chunk: truncate
			text = string([]rune(text)[:extractMaxChars])
			add = extractMaxChars
		}
		b.WriteString(text)
		n += add
		batch = append(batch, c)
	}
	open, err := loops.ListN(w.s, "open", maxOpenLoops)
	if err != nil {
		return false, err
	}
	app := th.AppName
	if app == "" {
		app = th.AppBundle
	}
	title := th.Title
	if title == "" {
		title = th.Key
	}
	cctx, cancel := context.WithTimeout(ctx, providerTimeout)
	res, err := w.x.Extract(cctx, provider.ExtractRequest{App: app, Thread: title, Text: b.String(), OpenLoops: open, Now: now})
	cancel()
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	bids := ids(batch)
	if err != nil {
		w.setErr("extract", err)
		return false, w.s.FailChunks("extract", bids, err.Error(), w.retryAt(now))
	}
	// Some of the batch may have been purged while the provider was working:
	// drop the result rather than keep loops from deleted text. Surviving
	// chunks stay pending and are extracted again without the purged text.
	if ok, err := w.s.ChunksExist(bids); err != nil || !ok {
		return false, err
	}
	changed, err = loops.Apply(w.s, res, app, tid, now)
	if err != nil {
		return false, err
	}
	if err := w.s.SetChunkStatus("extract", bids, "done"); err != nil {
		return changed, err
	}
	w.setErr("extract", nil)
	return changed, nil
}
