// Package mcpserver is the `notch mcp` server: a Model Context Protocol server
// over stdio that lets Claude Desktop, Claude Code and Cursor search the
// user's local memory and list or resolve open loops. Reads go straight to a
// read-only memory.db; the one write (resolve_loop) is sent to the running
// core through Deps.Resolve.
package mcpserver

import (
	"context"
	"errors"
	"io"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Instructions is sent to clients in the initialize result.
const Instructions = "Personal memory from the user's screen, stored on their Mac. Use search_memory for anything the user saw, read or wrote; use list_open_loops for commitments."

// Messages returned as tool errors.
const (
	MsgMemoryOff   = "PlatyNotch memory is off. Turn it on in PlatyNotch settings."
	MsgCoreNotUp   = "PlatyNotch is not running."
	serverName     = "platynotch"
	serverVersion  = "1"
	maxThreadChars = 20000
)

// ErrCoreDown is what a Resolve implementation returns when it cannot reach
// the core.
var ErrCoreDown = errors.New(MsgCoreNotUp)

// Deps are the server's dependencies. A nil Store means memory is off.
type Deps struct {
	Store    *store.Store      // opened read-only
	Embedder provider.Embedder // nil: keyword search only
	// Resolve sends loop.set_status to the running core.
	Resolve func(ctx context.Context, s protocol.LoopSetStatus) error
}

// NewServer builds the MCP server with the five memory tools registered.
func NewServer(deps Deps) *mcp.Server {
	s := mcp.NewServer(&mcp.Implementation{Name: serverName, Version: serverVersion}, &mcp.ServerOptions{Instructions: Instructions})
	registerTools(s, deps)
	return s
}

// Serve runs the server over in/out (newline-delimited JSON-RPC) until the
// client disconnects or ctx is cancelled. Nothing else may write to out.
func Serve(ctx context.Context, in io.Reader, out io.Writer, deps Deps) error {
	t := &mcp.IOTransport{Reader: io.NopCloser(in), Writer: nopWriteCloser{out}}
	err := NewServer(deps).Run(ctx, t)
	if err != nil && (errors.Is(err, io.EOF) || errors.Is(err, context.Canceled)) {
		return nil
	}
	return err
}

type nopWriteCloser struct{ io.Writer }

func (nopWriteCloser) Close() error { return nil }
