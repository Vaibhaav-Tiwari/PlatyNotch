// Package engine composes the memory store, ingester, search, background
// worker and open loops into the memory.Service that `notch serve` hands to
// the core server.
package engine

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/graph"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/ingest"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/loops"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/search"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/worker"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

const (
	tickEvery  = 10 * time.Second
	purgeEvery = 24 * time.Hour
)

var errClosed = errors.New("memory engine is closed")

// Engine implements memory.Service. Background work (embedding, extraction,
// the hourly stale-loop sweep and the daily retention purge) runs on one
// goroutine started by Open and stopped by Close.
type Engine struct {
	s     *store.Store
	ing   *ingest.Ingester
	w     *worker.Worker
	emb   provider.Embedder
	ext   provider.Extractor
	cfg   config.Memory
	now   func() time.Time
	wake  chan struct{}
	setup string // provider construction errors, shown in Status

	mu  sync.Mutex
	cbs []func([]protocol.Loop)

	closeMu sync.Mutex
	closed  bool
	cancel  context.CancelFunc
	done    chan struct{}
}

var _ memory.Service = (*Engine)(nil)

// OpenFromConfig opens the engine at paths.MemoryDB(). It returns nil, nil
// when memory is disabled.
func OpenFromConfig(cfg config.Config) (memory.Service, error) {
	if !cfg.Memory.Enabled {
		return nil, nil
	}
	if err := paths.EnsureHome(); err != nil {
		return nil, err
	}
	e, err := Open(paths.MemoryDB(), cfg.Memory, nil)
	if err != nil {
		return nil, err
	}
	return e, nil
}

// Open opens (creating if needed) the memory database at path and starts
// background work. now defaults to time.Now. A provider that cannot be built
// is treated as "none" and reported in Status().LastError, so memory still
// captures and searches by keyword.
func Open(path string, cfg config.Memory, now func() time.Time) (*Engine, error) {
	return open(path, cfg, now, nil)
}

// open is Open with an optional tick channel replacing the 10 s ticker.
func open(path string, cfg config.Memory, now func() time.Time, tick <-chan time.Time) (*Engine, error) {
	if now == nil {
		now = time.Now
	}
	s, err := store.Open(path, false)
	if err != nil {
		return nil, err
	}
	e := &Engine{s: s, cfg: cfg, now: now, wake: make(chan struct{}, 1), done: make(chan struct{})}
	var setup []string
	if e.emb, err = provider.NewEmbedder(cfg.Embedder); err != nil {
		e.emb = nil
		setup = append(setup, "embedder: "+err.Error())
	}
	if e.ext, err = provider.NewExtractor(cfg.Extractor); err != nil {
		e.ext = nil
		setup = append(setup, "extractor: "+err.Error())
	}
	e.setup = strings.Join(setup, "; ")

	// Chunks skipped while a provider was off, or failed during an outage,
	// are processed now that it is on; a changed embedding model re-embeds
	// everything it has no vector for.
	for kind, on := range map[string]bool{"embed": e.emb != nil, "extract": e.ext != nil} {
		if !on {
			continue
		}
		if _, err := s.ResetSkipped(kind); err != nil {
			s.Close()
			return nil, fmt.Errorf("reset skipped %s: %w", kind, err)
		}
		if _, err := s.RequeueFailed(kind); err != nil {
			s.Close()
			return nil, fmt.Errorf("requeue failed %s: %w", kind, err)
		}
	}
	if e.emb != nil {
		if _, err := s.RequeueOtherModel(e.emb.Model()); err != nil {
			s.Close()
			return nil, fmt.Errorf("requeue for model: %w", err)
		}
	}
	lastPurge := now()
	if err := e.purge(lastPurge); err != nil {
		s.Close()
		return nil, fmt.Errorf("retention purge: %w", err)
	}

	e.ing = ingest.New(s, cfg, now)
	e.w = worker.New(s, e.emb, e.ext, now)
	e.w.OnLoopsChanged(e.notify)

	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel
	if tick == nil {
		t := time.NewTicker(tickEvery)
		tick = t.C
		go func() { <-e.done; t.Stop() }()
	}
	go e.run(ctx, tick, lastPurge)
	return e, nil
}

// run drives the worker: once now, then on every tick or wake-up (after an
// ingest), purging old captures once a day.
func (e *Engine) run(ctx context.Context, tick <-chan time.Time, lastPurge time.Time) {
	defer close(e.done)
	for {
		e.w.Tick(ctx)
		if now := e.now(); now.Sub(lastPurge) >= purgeEvery {
			// A failed purge is retried on the next tick.
			if err := e.purge(now); err == nil {
				lastPurge = now
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-tick:
		case <-e.wake:
		}
	}
}

// purge deletes captures older than the retention window (0 keeps forever).
func (e *Engine) purge(now time.Time) error {
	if e.cfg.RetentionDays <= 0 {
		return nil
	}
	_, err := e.s.PurgeBefore(now.AddDate(0, 0, -e.cfg.RetentionDays))
	return err
}

func (e *Engine) isClosed() bool {
	e.closeMu.Lock()
	defer e.closeMu.Unlock()
	return e.closed
}

// Ingest stores one capture and wakes the worker if it produced new chunks.
func (e *Engine) Ingest(_ context.Context, c protocol.CaptureText) error {
	if e.isClosed() {
		return errClosed
	}
	n, err := e.ing.Ingest(c)
	if err != nil {
		return err
	}
	if n > 0 {
		select {
		case e.wake <- struct{}{}:
		default:
		}
	}
	return nil
}

func (e *Engine) Search(ctx context.Context, q protocol.MemorySearch) ([]protocol.MemoryHit, error) {
	if e.isClosed() {
		return nil, errClosed
	}
	return search.Search(ctx, e.s, e.emb, q)
}

func (e *Engine) Graph(_ context.Context, q protocol.MemoryGraphQuery) (protocol.MemoryGraph, error) {
	if e.isClosed() {
		return protocol.MemoryGraph{}, errClosed
	}
	return graph.Build(e.s, q, e.now())
}

func (e *Engine) Loops(_ context.Context, status string) ([]protocol.Loop, error) {
	if e.isClosed() {
		return nil, errClosed
	}
	return loops.List(e.s, status)
}

// SetLoopStatus changes a loop's status and, on success, notifies
// OnLoopsChanged subscribers with the open loops.
func (e *Engine) SetLoopStatus(_ context.Context, st protocol.LoopSetStatus) error {
	if e.isClosed() {
		return errClosed
	}
	if err := loops.SetStatus(e.s, st, e.now()); err != nil {
		return err
	}
	open, err := loops.List(e.s, "open")
	if err != nil {
		return err
	}
	e.notify(open)
	return nil
}

// OnLoopsChanged registers fn, run with the open loops whenever the worker
// changes them or SetLoopStatus succeeds.
func (e *Engine) OnLoopsChanged(fn func([]protocol.Loop)) {
	e.mu.Lock()
	e.cbs = append(e.cbs, fn)
	e.mu.Unlock()
}

func (e *Engine) notify(open []protocol.Loop) {
	e.mu.Lock()
	cbs := slices.Clone(e.cbs)
	e.mu.Unlock()
	for _, fn := range cbs {
		fn(open)
	}
}

func (e *Engine) Status() protocol.MemoryStatus {
	st := protocol.MemoryStatus{Enabled: true, Embedder: "none", Extractor: "none"}
	if e.emb != nil {
		st.Embedder = label(e.emb.Name(), e.emb.Model())
	}
	if e.ext != nil {
		model := e.cfg.Extractor.Model
		if m, ok := e.ext.(interface{ Model() string }); ok {
			model = m.Model()
		}
		st.Extractor = label(e.ext.Name(), model)
	}
	errs := []string{}
	if e.setup != "" {
		errs = append(errs, e.setup)
	}
	if e.isClosed() {
		errs = append(errs, errClosed.Error())
	} else if t, v, c, p, err := e.s.Counts(); err != nil {
		errs = append(errs, "counts: "+err.Error())
	} else {
		st.Threads, st.Versions, st.Chunks, st.Pending = t, v, c, p
	}
	if w := e.w.LastError(); w != "" {
		errs = append(errs, w)
	}
	st.LastError = strings.Join(errs, "; ")
	return st
}

func label(name, model string) string {
	if model == "" {
		return name
	}
	return name + "/" + model
}

// Close stops background work, waits for it, then closes the store. It is
// safe to call more than once.
func (e *Engine) Close() error {
	e.closeMu.Lock()
	if e.closed {
		e.closeMu.Unlock()
		return nil
	}
	e.closed = true
	e.closeMu.Unlock()
	e.cancel()
	<-e.done
	return e.s.Close()
}
