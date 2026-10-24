package server

import (
	"context"
	"encoding/json"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/ext"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

const (
	memoryOff      = "memory is off"
	requestTimeout = 30 * time.Second
)

// handleUI serves every non-hook message. Requests that may be slow (memory
// search and graph, loop status, extension requests) run on their own goroutine
// (goRequest) and reply by ID.
func (s *Server) handleUI(ctx context.Context, c *conn, env protocol.Envelope) {
	id := env.ID
	switch env.Type {
	case protocol.TypeHello:
		var h protocol.Hello
		if err := env.Decode(&h); err != nil {
			c.replyErr(id, "bad hello: "+err.Error())
			return
		}
		s.mu.Lock()
		c.role = h.Role
		s.checkDecidersLocked()
		s.mu.Unlock()

	case protocol.TypePing:
		c.reply(protocol.TypePong, id, nil)

	case protocol.TypeSubscribe:
		loops, ms := s.memView()
		s.mu.Lock()
		snap := s.snapshotLocked(loops, ms)
		if c.send(protocol.MustNew(protocol.TypeSnapshot, id, snap)) {
			s.subs[c] = struct{}{}
			s.checkDecidersLocked()
		}
		s.mu.Unlock()

	case protocol.TypeApprovalDecide:
		var d protocol.ApprovalDecide
		if err := env.Decode(&d); err != nil {
			c.replyErr(id, "bad approval.decide: "+err.Error())
			return
		}
		if d.Source == "" {
			d.Source = "notch"
		}
		if err := s.Decide(d); err != nil {
			c.replyErr(id, err.Error())
		}

	case protocol.TypeLoopSetStatus:
		var ls protocol.LoopSetStatus
		if err := env.Decode(&ls); err != nil {
			c.replyErr(id, "bad loop.set_status: "+err.Error())
			return
		}
		if s.mem == nil {
			c.replyErr(id, memoryOff)
			return
		}
		s.goRequest(func() {
			rctx, cancel := context.WithTimeout(ctx, requestTimeout)
			defer cancel()
			if err := s.mem.SetLoopStatus(rctx, ls); err != nil {
				c.replyErr(id, err.Error())
				return
			}
			c.reply(protocol.TypeLoopSetStatus, id, nil)
		})

	case protocol.TypeMemorySearch:
		var q protocol.MemorySearch
		if err := env.Decode(&q); err != nil {
			c.replyErr(id, "bad memory.search: "+err.Error())
			return
		}
		if s.mem == nil {
			c.replyErr(id, memoryOff)
			return
		}
		s.goRequest(func() {
			rctx, cancel := context.WithTimeout(ctx, requestTimeout)
			defer cancel()
			hits, err := s.mem.Search(rctx, q)
			if err != nil {
				c.replyErr(id, err.Error())
				return
			}
			if hits == nil {
				hits = []protocol.MemoryHit{}
			}
			c.reply(protocol.TypeMemoryResults, id, protocol.MemoryResults{Hits: hits})
		})

	case protocol.TypeMemoryGraph:
		var q protocol.MemoryGraphQuery
		if err := env.Decode(&q); err != nil {
			c.replyErr(id, "bad memory.graph: "+err.Error())
			return
		}
		if s.mem == nil {
			c.replyErr(id, memoryOff)
			return
		}
		s.goRequest(func() {
			rctx, cancel := context.WithTimeout(ctx, requestTimeout)
			defer cancel()
			g, err := s.mem.Graph(rctx, q)
			if err != nil {
				c.replyErr(id, err.Error())
				return
			}
			c.reply(protocol.TypeMemoryGraph, id, g)
		})

	case protocol.TypeCaptureText:
		if s.mem == nil {
			return // memory off: captures are dropped silently
		}
		var ct protocol.CaptureText
		if err := env.Decode(&ct); err != nil {
			c.replyErr(id, "bad capture.text: "+err.Error())
			return
		}
		// In order on the capture connection, so captures are never reordered.
		rctx, cancel := context.WithTimeout(ctx, requestTimeout)
		defer cancel()
		if err := s.mem.Ingest(rctx, ct); err != nil {
			s.logf("ingest: %v", err)
		}

	case protocol.TypeConfigReload:
		cfg, err := config.Load()
		if err != nil {
			c.replyErr(id, "config reload: "+err.Error())
			return
		}
		s.mu.Lock()
		s.cfg = cfg
		s.mu.Unlock()
		c.reply(protocol.TypeNotice, id, protocol.Notice{Kind: "info", Title: "Configuration reloaded"})

	case protocol.TypeExtRequest:
		var m protocol.ExtMessage
		if err := env.Decode(&m); err != nil {
			c.replyErr(id, "bad ext.request: "+err.Error())
			return
		}
		h := s.requestHandler(m.Ext)
		if h == nil {
			c.replyErr(id, "no extension handles "+m.Ext)
			return
		}
		s.goRequest(func() {
			rctx, cancel := context.WithTimeout(ctx, requestTimeout)
			defer cancel()
			out, err := h.HandleRequest(rctx, m.Kind, m.Data)
			if err != nil {
				c.replyErr(id, err.Error())
				return
			}
			raw, err := json.Marshal(out)
			if err != nil {
				c.replyErr(id, "encode reply: "+err.Error())
				return
			}
			c.reply(protocol.TypeExtRequest, id, protocol.ExtMessage{Ext: m.Ext, Kind: m.Kind, Data: raw})
		})

	default:
		c.replyErr(id, "unknown message type "+env.Type)
	}
}

// goRequest runs a slow request on its own goroutine tracked by the server's
// WaitGroup, so Serve returns only after it finishes and the memory service
// (closed by the caller after Serve) is never used by a straggler. It is
// called from a connection goroutine, itself counted in wg, so the Add never
// races Serve's Wait.
func (s *Server) goRequest(f func()) {
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		f()
	}()
}

func (s *Server) requestHandler(name string) ext.RequestHandler {
	for _, e := range s.opts.Extensions {
		if e.Name() != name {
			continue
		}
		if h, ok := e.(ext.RequestHandler); ok {
			return h
		}
	}
	return nil
}
