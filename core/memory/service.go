// Package memory defines the local memory service the core talks to. The
// implementation (capture ingestion, embeddings, open-loop extraction) lands
// in Plan 2; the server only depends on this interface, and a nil Service
// means memory is off.
package memory

import (
	"context"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// Service is the memory engine behind capture.text, memory.search,
// memory.graph and loops.
type Service interface {
	Ingest(ctx context.Context, c protocol.CaptureText) error
	Search(ctx context.Context, q protocol.MemorySearch) ([]protocol.MemoryHit, error)
	// Graph returns the apps, threads, sites and open loops active in q's window.
	Graph(ctx context.Context, q protocol.MemoryGraphQuery) (protocol.MemoryGraph, error)
	Loops(ctx context.Context, status string) ([]protocol.Loop, error)
	SetLoopStatus(ctx context.Context, s protocol.LoopSetStatus) error
	Status() protocol.MemoryStatus
	// OnLoopsChanged registers a callback run whenever the open loops change.
	OnLoopsChanged(fn func([]protocol.Loop))
	Close() error
}
