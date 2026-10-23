package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"sync"
	"time"

	"github.com/platynotch/platynotch/core/protocol"
	"github.com/platynotch/platynotch/core/wire"
)

// writeTimeout bounds one socket write so a stuck peer cannot pin a goroutine.
const writeTimeout = 5 * time.Second

// conn is one client connection. Replies and broadcasts go through a bounded
// queue drained by writeLoop; hook replies are written directly (a hook
// connection never subscribes, so there is nothing to interleave with).
type conn struct {
	s    *Server
	nc   net.Conn
	r    *wire.Reader
	w    *wire.Writer
	role string // from hello; "" until then

	out  chan protocol.Envelope
	done chan struct{}
	once sync.Once
}

func newConn(s *Server, nc net.Conn) *conn {
	return &conn{
		s: s, nc: nc,
		r:    wire.NewReader(nc),
		w:    wire.NewWriter(nc),
		out:  make(chan protocol.Envelope, queueSize),
		done: make(chan struct{}),
	}
}

// send enqueues env without blocking. It returns false, and closes the
// connection, if the queue is full; false without side effects if closed.
func (c *conn) send(env protocol.Envelope) bool {
	select {
	case <-c.done:
		return false
	default:
	}
	select {
	case c.out <- env:
		return true
	default:
		c.s.logf("client too slow (%d queued); disconnecting", queueSize)
		c.close()
		return false
	}
}

// reply enqueues a reply to a request carrying id.
func (c *conn) reply(typ, id string, data any) {
	env, err := protocol.New(typ, id, data)
	if err != nil {
		c.s.logf("encode %s: %v", typ, err)
		return
	}
	c.send(env)
}

func (c *conn) replyErr(id, msg string) {
	c.reply(protocol.TypeError, id, protocol.ErrorMsg{Message: msg})
}

// writeNow writes synchronously (hook replies).
func (c *conn) writeNow(typ, id string, data any) error {
	c.nc.SetWriteDeadline(time.Now().Add(writeTimeout))
	return c.w.Send(typ, id, data)
}

func (c *conn) close() {
	c.once.Do(func() {
		close(c.done)
		c.nc.Close()
	})
}

func (c *conn) writeLoop() {
	defer c.s.wg.Done()
	for {
		select {
		case env := <-c.out:
			c.nc.SetWriteDeadline(time.Now().Add(writeTimeout))
			if err := c.w.Write(env); err != nil {
				c.close()
				return
			}
		case <-c.done:
			return
		}
	}
}

// serve reads requests until EOF. A hook.event takes over the connection: a
// hook connection carries exactly one event and is closed after its reply.
func (c *conn) serve(ctx context.Context) {
	defer c.s.wg.Done()
	defer func() {
		c.s.mu.Lock()
		delete(c.s.subs, c)
		delete(c.s.conns, c)
		c.s.expireIfNoDecidersLocked()
		c.s.mu.Unlock()
		c.close()
	}()
	for {
		env, err := c.r.Read()
		if isDecodeErr(err) {
			c.replyErr("", "malformed message: "+err.Error())
			continue
		}
		if err != nil {
			if err != io.EOF {
				select {
				case <-c.done:
				default:
					c.s.logf("read: %v", err)
				}
			}
			return
		}
		if env.Type == protocol.TypeHookEvent {
			c.s.handleHook(ctx, c, env)
			return
		}
		c.s.handleUI(ctx, c, env)
	}
}

// watchGone keeps reading a hook connection (discarding input) and closes
// the returned channel when the peer disconnects or the connection is closed.
func (c *conn) watchGone() <-chan struct{} {
	gone := make(chan struct{})
	go func() {
		defer close(gone)
		for {
			if _, err := c.r.Read(); err != nil && !isDecodeErr(err) {
				return
			}
		}
	}()
	return gone
}

// isDecodeErr reports a bad JSON line; the reader can continue past it.
func isDecodeErr(err error) bool {
	var se *json.SyntaxError
	var te *json.UnmarshalTypeError
	return errors.As(err, &se) || errors.As(err, &te)
}
