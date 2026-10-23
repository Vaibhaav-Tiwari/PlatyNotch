// Package memory defines the local memory service the core talks to. The
// implementation (capture ingestion, embeddings, open-loop extraction) lands
// in Plan 2; the server only depends on this interface, and a nil Service
// means memory is off.
package memory

import (
	"context"

	"github.com/platynotch/platynotch/core/protocol"
)

// Service is the memory engine behind capture.text, memory.search and loops.
type Service interface {
	Ingest(ctx context.Context, c protocol.CaptureText) error
	Search(ctx context.Context, q protocol.MemorySearch) ([]protocol.MemoryHit, error)
	Loops(ctx context.Context, status string) ([]protocol.Loop, error)
	SetLoopStatus(ctx context.Context, s protocol.LoopSetStatus) error
	Status() protocol.MemoryStatus
	// OnLoopsChanged registers a callback run whenever the open loops change.
	OnLoopsChanged(fn func([]protocol.Loop))
	Close() error
}
