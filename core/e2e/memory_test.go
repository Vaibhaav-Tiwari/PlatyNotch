package e2e

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/engine"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/server"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/wire"
)

const mailText = "Hi Sam, about the Lisbon offsite budget: I will send the report by Friday afternoon."

func (e *env) enableMemory(t *testing.T) {
	t.Helper()
	cfg := config.Default()
	cfg.Memory.Enabled = true
	if err := config.SaveFile(filepath.Join(e.home, "config.json"), cfg); err != nil {
		t.Fatal(err)
	}
}

// The real `notch serve` opens memory when it is enabled: a UI client's
// capture is searchable straight away (keyword search, no providers).
func TestCaptureToSearch(t *testing.T) {
	e := newEnv(t)
	e.enableMemory(t)
	e.serve(t)
	u := e.subscribeUI(t)

	if err := u.w.Send(protocol.TypeCaptureText, "", protocol.CaptureText{
		AppBundle: "com.apple.mail", AppName: "Mail", WindowTitle: "Offsite", Text: mailText, CapturedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := u.w.Send(protocol.TypeMemorySearch, "q1", protocol.MemorySearch{Query: "lisbon budget"}); err != nil {
		t.Fatal(err)
	}
	var res protocol.MemoryResults
	if err := u.next(protocol.TypeMemoryResults).Decode(&res); err != nil {
		t.Fatal(err)
	}
	if len(res.Hits) != 1 || !strings.Contains(res.Hits[0].Snippet, "Lisbon") {
		t.Fatalf("hits: %+v", res.Hits)
	}
	if _, err := os.Stat(filepath.Join(e.home, "memory.db")); err != nil {
		t.Fatalf("memory.db: %v", err)
	}
	// The same capture is a thread in the graph, linked to its app.
	if err := u.w.Send(protocol.TypeMemoryGraph, "g1", protocol.MemoryGraphQuery{Hours: 24}); err != nil {
		t.Fatal(err)
	}
	var g protocol.MemoryGraph
	if err := u.next(protocol.TypeMemoryGraph).Decode(&g); err != nil {
		t.Fatal(err)
	}
	if len(g.Nodes) != 2 || len(g.Edges) != 1 || g.Edges[0].Kind != protocol.EdgeIn {
		t.Fatalf("graph: %+v", g)
	}
}

type e2eExt struct{}

func (e2eExt) Name() string { return "e2e-fake" }
func (e2eExt) Extract(_ context.Context, r provider.ExtractRequest) (provider.ExtractResult, error) {
	if !strings.Contains(r.Text, "I will send the report") {
		return provider.ExtractResult{}, nil
	}
	return provider.ExtractResult{Loops: []protocol.Loop{{Title: "Send Sam the report", Kind: "commitment", Quote: "I will send the report"}}}, nil
}

// A fake extractor (registered by name and selected in config) finds a loop
// in a capture; the server pushes loops.updated, and again after the UI
// dismisses it. Runs in-process because the provider lives in the test.
func TestLoopsUpdatedOverSocket(t *testing.T) {
	provider.RegisterExtractor("e2e-fake", func(config.Provider) (provider.Extractor, error) { return e2eExt{}, nil })
	e := newEnv(t)
	t.Setenv("PLATYNOTCH_HOME", e.home)
	cfg := config.Default()
	cfg.Memory.Enabled = true
	cfg.Memory.Extractor = config.Provider{Name: "e2e-fake"}
	mem, err := engine.OpenFromConfig(cfg)
	if err != nil || mem == nil {
		t.Fatalf("open memory: %v %v", mem, err)
	}
	defer mem.Close()
	srv, err := server.New(server.Options{Socket: e.sock, Config: cfg, Memory: mem})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() { served <- srv.Serve(ctx) }()
	defer func() { cancel(); <-served }()
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if nc, err := net.Dial("unix", e.sock); err == nil {
			nc.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("server never listened")
		}
	}
	u := e.subscribeUI(t)

	// Captured ten minutes ago, so the thread is already quiet enough to extract.
	if err := u.w.Send(protocol.TypeCaptureText, "", protocol.CaptureText{
		AppBundle: "com.apple.mail", AppName: "Mail", WindowTitle: "Offsite", Text: mailText,
		CapturedAt: time.Now().Add(-10 * time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	var ls []protocol.Loop
	if err := u.next(protocol.TypeLoopsUpdated).Decode(&ls); err != nil {
		t.Fatal(err)
	}
	if len(ls) != 1 || ls[0].Title != "Send Sam the report" || ls[0].SourceApp != "Mail" {
		t.Fatalf("loops.updated: %+v", ls)
	}

	if err := u.w.Send(protocol.TypeLoopSetStatus, "l1", protocol.LoopSetStatus{ID: ls[0].ID, Status: "dismissed"}); err != nil {
		t.Fatal(err)
	}
	if err := u.next(protocol.TypeLoopsUpdated).Decode(&ls); err != nil {
		t.Fatal(err)
	}
	if len(ls) != 0 {
		t.Fatalf("after dismiss: %+v", ls)
	}

	// A fresh subscriber's snapshot carries memory status from the engine.
	nc, err := net.Dial("unix", e.sock)
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	w, r := wire.NewWriter(nc), wire.NewReader(nc)
	if err := w.Send(protocol.TypeSubscribe, "s2", nil); err != nil {
		t.Fatal(err)
	}
	u2 := &ui{t: t, nc: nc, r: r, w: w}
	var snap protocol.Snapshot
	if err := u2.next(protocol.TypeSnapshot).Decode(&snap); err != nil {
		t.Fatal(err)
	}
	if !snap.Memory.Enabled || snap.Memory.Chunks != 1 || snap.Memory.Extractor != "e2e-fake" {
		t.Fatalf("snapshot memory: %+v", snap.Memory)
	}
}
