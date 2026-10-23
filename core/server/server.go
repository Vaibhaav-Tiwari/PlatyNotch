// Package server is the core of `notch serve`: a Unix-socket server that
// folds agent hook events into session state, runs the approval flow between
// hooks and deciders (UI clients and extensions), and hosts extensions.
//
// Concurrency: s.mu guards server state (subscribers, deciders, policies,
// auditors, config, usage) and is also held around every session-store or
// approval-manager mutation together with the broadcast it causes, so a new
// subscriber's snapshot and the update stream line up. Broadcasting only
// enqueues onto bounded per-subscriber queues; no lock is ever held while
// writing to a socket or calling extension code.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents/all" // register every adapter
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/approval"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/ext"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/session"
)

// queueSize bounds each subscriber's outbound queue. A UI client that falls
// this far behind is disconnected; an extension subscriber drops events.
const queueSize = 256

// staleDialTimeout is how long Serve waits for an existing socket to answer
// before treating it as stale.
const staleDialTimeout = 200 * time.Millisecond

// NoDeciderGrace is how long pending approvals survive after the last decider
// (UI subscriber or registered extension decider) goes away, e.g. while the
// Mac app restarts or updates.
const NoDeciderGrace = 5 * time.Second

// noDeciderGrace is NoDeciderGrace, overridable by tests before New.
var noDeciderGrace = NoDeciderGrace

type Options struct {
	Socket, Edition string
	Config          config.Config
	Memory          memory.Service
	Extensions      []ext.Extension
	Now             func() time.Time
	Logf            func(string, ...any)
}

type Server struct {
	opts  Options
	now   func() time.Time
	logf  func(string, ...any)
	mem   memory.Service
	store *session.Store
	mgr   *approval.Manager

	mu         sync.Mutex
	cfg        config.Config
	usage      protocol.Usage
	subs       map[*conn]struct{}   // subscribed connections
	extSubs    map[*extSub]struct{} // Host.Subscribe callbacks
	conns      map[*conn]struct{}   // every open connection
	deciders   int                  // RegisterDecider registrations
	policies   []policy.Provider    // extension policies, before local rules
	auditors   []ext.Auditor
	serving    bool
	closed     bool          // Serve is shutting down
	grace      time.Duration // copy of noDeciderGrace taken in New
	graceTimer *time.Timer   // armed while there are no deciders

	wg sync.WaitGroup
}

var _ ext.Host = (*Server)(nil)

func New(o Options) (*Server, error) {
	if o.Socket == "" {
		return nil, errors.New("server: no socket path")
	}
	if o.Edition == "" {
		o.Edition = "free"
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Logf == nil {
		o.Logf = func(string, ...any) {}
	}
	s := &Server{
		opts:    o,
		now:     o.Now,
		logf:    o.Logf,
		mem:     o.Memory,
		store:   session.NewStore(o.Now, nil),
		mgr:     approval.NewManager(o.Now),
		cfg:     o.Config,
		subs:    map[*conn]struct{}{},
		extSubs: map[*extSub]struct{}{},
		conns:   map[*conn]struct{}{},
		grace:   noDeciderGrace,
	}
	if s.mem != nil {
		s.mem.OnLoopsChanged(func(loops []protocol.Loop) {
			if loops == nil {
				loops = []protocol.Loop{}
			}
			s.broadcast(protocol.MustNew(protocol.TypeLoopsUpdated, "", loops))
		})
	}
	return s, nil
}

// Serve listens on the socket and serves until ctx is cancelled. An existing
// socket file is replaced only if no process answers on it. It starts every
// extension before accepting connections.
func (s *Server) Serve(ctx context.Context) error {
	s.mu.Lock()
	if s.serving {
		s.mu.Unlock()
		return errors.New("server: already serving")
	}
	s.serving = true
	s.mu.Unlock()

	ln, err := listen(s.opts.Socket)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	for _, e := range s.opts.Extensions {
		if err := e.Start(ctx, s); err != nil {
			s.logf("extension %s failed to start: %v", e.Name(), err)
		}
	}

	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	var acceptErr error
	for {
		nc, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			acceptErr = err
			break
		}
		if !peerAllowed(nc) {
			s.logf("rejected connection from another user")
			nc.Close()
			continue
		}
		c := newConn(s, nc)
		s.mu.Lock()
		s.conns[c] = struct{}{}
		s.mu.Unlock()
		s.wg.Add(2)
		go c.writeLoop()
		go c.serve(ctx)
	}

	cancel()
	s.mu.Lock()
	s.closed = true
	if s.graceTimer != nil {
		s.graceTimer.Stop()
		s.graceTimer = nil
	}
	for c := range s.conns {
		c.close()
	}
	for e := range s.extSubs {
		e.stop()
	}
	s.mu.Unlock()
	s.wg.Wait()
	os.Remove(s.opts.Socket)
	return acceptErr
}

// listen replaces a stale socket (nothing answering) and refuses to touch a
// live one or a non-socket file. The socket is owner-only.
func listen(path string) (net.Listener, error) {
	if st, err := os.Lstat(path); err == nil {
		if st.Mode()&fs.ModeSocket == 0 {
			return nil, fmt.Errorf("server: %s exists and is not a socket", path)
		}
		if c, err := net.DialTimeout("unix", path, staleDialTimeout); err == nil {
			c.Close()
			return nil, fmt.Errorf("server: already running on %s", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, fmt.Errorf("server: remove stale socket: %w", err)
		}
	}
	// Bind under a temporary name and chmod before renaming into place, so
	// the socket is never reachable at the real path with looser permissions.
	tmp := filepath.Join(filepath.Dir(path), fmt.Sprintf(".notch-%d.sock", os.Getpid()))
	os.Remove(tmp)
	ln, err := net.Listen("unix", tmp)
	if err != nil {
		return nil, err
	}
	ln.(*net.UnixListener).SetUnlinkOnClose(false) // Serve removes the real path
	if err := os.Chmod(tmp, 0o600); err != nil {
		ln.Close()
		os.Remove(tmp)
		return nil, err
	}
	if err := os.Rename(tmp, path); err != nil {
		ln.Close()
		os.Remove(tmp)
		return nil, err
	}
	return ln, nil
}

// broadcast enqueues env for every subscriber.
func (s *Server) broadcast(env protocol.Envelope) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.broadcastLocked(env)
}

func (s *Server) broadcastLocked(env protocol.Envelope) {
	for c := range s.subs {
		if !c.send(env) {
			delete(s.subs, c) // overflowed or closed; send already closed it
		}
	}
	for e := range s.extSubs {
		select {
		case e.ch <- env:
		default:
			s.logf("extension subscriber is behind; dropped %s", env.Type)
		}
	}
}

// decidersLocked counts subscribed UI connections plus registered deciders.
func (s *Server) decidersLocked() int {
	n := s.deciders
	for c := range s.subs {
		if c.role == protocol.RoleUI {
			n++
		}
	}
	return n
}

// checkDecidersLocked runs after any change to the set of deciders. When the
// count drops to zero it arms a grace timer; a decider (re)appearing before it
// fires cancels it, so a Mac-app restart keeps in-flight approvals (the new
// UI sees them in its snapshot). If the timer fires with still nobody able to
// answer, pending approvals expire and the hooks fall back to the agent's own
// prompt instead of waiting for the full approval timeout.
func (s *Server) checkDecidersLocked() {
	if s.decidersLocked() > 0 {
		if s.graceTimer != nil {
			s.graceTimer.Stop()
			s.graceTimer = nil
		}
		return
	}
	if s.graceTimer != nil || s.closed {
		return
	}
	var t *time.Timer
	t = time.AfterFunc(s.grace, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.graceTimer != t {
			return // cancelled (and possibly re-armed) meanwhile
		}
		s.graceTimer = nil
		if s.decidersLocked() > 0 {
			return
		}
		for _, a := range s.mgr.Pending() {
			s.mgr.ExpireWith(a.ID, "no-decider")
		}
	})
	s.graceTimer = t
}

// memView reads memory state for a snapshot. It never runs under s.mu.
func (s *Server) memView() ([]protocol.Loop, protocol.MemoryStatus) {
	loops := []protocol.Loop{}
	if s.mem == nil {
		return loops, protocol.MemoryStatus{Enabled: false}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if l, err := s.mem.Loops(ctx, "open"); err != nil {
		s.logf("memory loops: %v", err)
	} else if l != nil {
		loops = l
	}
	return loops, s.mem.Status()
}

func (s *Server) snapshotLocked(loops []protocol.Loop, ms protocol.MemoryStatus) protocol.Snapshot {
	return protocol.Snapshot{
		Sessions:  s.store.List(),
		Approvals: s.mgr.Pending(),
		Usage:     s.usage,
		Loops:     loops,
		Memory:    ms,
		Edition:   s.opts.Edition,
	}
}

// --- ext.Host ---

func (s *Server) Edition() string { return s.opts.Edition }

func (s *Server) Snapshot() protocol.Snapshot {
	loops, ms := s.memView()
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked(loops, ms)
}

type extSub struct {
	ch   chan protocol.Envelope
	done chan struct{}
	once sync.Once
}

func (e *extSub) stop() { e.once.Do(func() { close(e.done) }) }

func (s *Server) Subscribe(fn func(protocol.Envelope)) (cancel func()) {
	e := &extSub{ch: make(chan protocol.Envelope, queueSize), done: make(chan struct{})}
	s.mu.Lock()
	s.extSubs[e] = struct{}{}
	s.mu.Unlock()
	go func() {
		for {
			select {
			case env := <-e.ch:
				fn(env)
			case <-e.done:
				return
			}
		}
	}()
	return func() {
		s.mu.Lock()
		delete(s.extSubs, e)
		s.mu.Unlock()
		e.stop()
	}
}

// Decide answers a pending approval. Only allow and deny are accepted; the
// hook's goroutine delivers the decision and broadcasts approval.resolved.
func (s *Server) Decide(d protocol.ApprovalDecide) error {
	if d.Behavior != protocol.BehaviorAllow && d.Behavior != protocol.BehaviorDeny {
		return fmt.Errorf("behavior must be allow or deny, got %q", d.Behavior)
	}
	if d.Source == "" {
		d.Source = "ext"
	}
	return s.mgr.Decide(d)
}

func (s *Server) RegisterDecider(name string) (unregister func()) {
	s.mu.Lock()
	s.deciders++
	s.checkDecidersLocked()
	s.mu.Unlock()
	s.logf("decider %s registered", name)
	var once sync.Once
	return func() {
		once.Do(func() {
			s.mu.Lock()
			s.deciders--
			s.checkDecidersLocked()
			s.mu.Unlock()
		})
	}
}

func (s *Server) Memory() memory.Service { return s.mem }

func (s *Server) Config() config.Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cfg
}

func (s *Server) AddPolicy(p policy.Provider) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.policies = append(s.policies, p)
}

func (s *Server) AddAuditor(a ext.Auditor) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.auditors = append(s.auditors, a)
}

func (s *Server) EmitEvent(extName, kind string, data any) {
	raw, err := json.Marshal(data)
	if err != nil {
		s.logf("ext.event %s/%s: %v", extName, kind, err)
		return
	}
	s.broadcast(protocol.MustNew(protocol.TypeExtEvent, "", protocol.ExtMessage{Ext: extName, Kind: kind, Data: raw}))
}

func (s *Server) Logf(format string, args ...any) { s.logf(format, args...) }

// --- hooks for discovery, sweeping and usage (wired by `notch serve`) ---

// UpsertSessions adds discovered sessions and broadcasts the ones that changed.
func (s *Server) UpsertSessions(ss []protocol.Session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, in := range ss {
		before, had := s.store.Get(in.Key)
		s.store.Upsert(in)
		after, ok := s.store.Get(in.Key)
		if ok && (!had || before != after) {
			s.broadcastLocked(protocol.MustNew(protocol.TypeSessionUpdated, "", after))
		}
	}
}

// Sweep exits and removes dead sessions, broadcasting the changes.
func (s *Server) Sweep() {
	s.mu.Lock()
	defer s.mu.Unlock()
	changed, removed := s.store.Sweep(nil)
	for _, sess := range changed {
		s.broadcastLocked(protocol.MustNew(protocol.TypeSessionUpdated, "", sess))
	}
	for _, sess := range removed {
		s.broadcastLocked(protocol.MustNew(protocol.TypeSessionRemoved, "", protocol.SessionRemoved{Key: sess.Key}))
	}
}

// SetUsage stores the latest usage limits and broadcasts usage.updated.
func (s *Server) SetUsage(u protocol.Usage) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usage = u
	s.broadcastLocked(protocol.MustNew(protocol.TypeUsageUpdated, "", u))
}

func (s *Server) audit(e ext.AuditEvent) {
	s.mu.Lock()
	auditors := append([]ext.Auditor(nil), s.auditors...)
	s.mu.Unlock()
	for _, a := range auditors {
		a.Record(e)
	}
}
