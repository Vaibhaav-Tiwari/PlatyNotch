package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/mcpserver"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/loops"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/server"
)

func TestMCPStdoutIsOnlyJSONRPC(t *testing.T) {
	home, _, _ := env(t)
	in := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_open_loops","arguments":{}}}`,
	}, "\n") + "\n"
	// Like a real client, keep stdin open until the replies have arrived.
	pr, pw := io.Pipe()
	var out lockedBuf
	var errb bytes.Buffer
	codec := make(chan int, 1)
	go func() { codec <- Run(context.Background(), []string{"mcp"}, WithIO(pr, &out, &errb)) }()
	_, _ = pw.Write([]byte(in))
	deadline := time.Now().Add(5 * time.Second)
	for strings.Count(out.String(), "\n") < 3 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	pw.Close()
	r := result{<-codec, out.String(), errb.String()}
	if r.code != 0 {
		t.Fatalf("exit %d: %s", r.code, r.stderr)
	}
	lines := 0
	sc := bufio.NewScanner(strings.NewReader(r.stdout))
	sc.Buffer(nil, 1<<20)
	for sc.Scan() {
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil || m["jsonrpc"] != "2.0" {
			t.Fatalf("stdout line is not JSON-RPC: %q", sc.Text())
		}
		lines++
	}
	if lines != 3 {
		t.Fatalf("want 3 replies, got %d:\n%s", lines, r.stdout)
	}
	if !strings.Contains(r.stdout, mcpserver.MsgMemoryOff) {
		t.Fatalf("memory-off error missing:\n%s", r.stdout)
	}
	if _, err := os.Stat(filepath.Join(home, "logs", "mcp.log")); err != nil {
		t.Fatalf("mcp.log: %v", err)
	}
}

func TestMemSourceFollowsConfigAndDB(t *testing.T) {
	env(t)
	if err := paths.EnsureHome(); err != nil {
		t.Fatal(err)
	}
	src := &memSource{logger: log.New(io.Discard, "", 0)}
	defer src.Close()
	if st, _, err := src.get(); st != nil || err != nil {
		t.Fatalf("off at start: %v %v", st, err)
	}
	cfg := config.Default()
	cfg.Memory.Enabled = true
	if err := config.Save(cfg); err != nil {
		t.Fatal(err)
	}
	if st, _, _ := src.get(); st != nil {
		t.Fatal("enabled but no db should stay off")
	}
	w, err := store.Open(paths.MemoryDB(), false)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	st1, _, err := src.get()
	if st1 == nil || err != nil {
		t.Fatalf("db present and enabled: %v %v", st1, err)
	}
	if st2, _, _ := src.get(); st2 != st1 {
		t.Fatal("store not cached while nothing changed")
	}
}

// loopMemory is a memory.Service whose loop changes hit a real store.
type loopMemory struct {
	memory.Service
	mu sync.Mutex
	s  *store.Store
}

func (m *loopMemory) Loops(context.Context, string) ([]protocol.Loop, error) { return nil, nil }
func (m *loopMemory) Status() protocol.MemoryStatus                          { return protocol.MemoryStatus{Enabled: true} }
func (m *loopMemory) OnLoopsChanged(func([]protocol.Loop))                   {}
func (m *loopMemory) Close() error                                           { return nil }
func (m *loopMemory) SetLoopStatus(_ context.Context, st protocol.LoopSetStatus) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return loops.SetStatus(m.s, st, time.Now())
}

func TestResolveLoopAgainstRealCore(t *testing.T) {
	_, _, sock := env(t)
	s, err := store.Open(filepath.Join(t.TempDir(), "m.db"), false)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.ApplyLoops([]store.Loop{{Title: "Send draft", Kind: "task", TitleHash: "h1", DetectedAt: time.Now()}}, nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	open, err := loops.List(s, "open")
	if err != nil || len(open) != 1 {
		t.Fatalf("seed loop: %v %v", open, err)
	}
	srv, err := server.New(server.Options{Socket: sock, Config: config.Default(), Memory: &loopMemory{s: s}})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- srv.Serve(ctx) }()
	t.Cleanup(func() { cancel(); <-done })
	for i := 0; ; i++ {
		if c, err := dialCore(); err == nil {
			c.Close()
			break
		}
		if i > 100 {
			t.Fatal("core never came up")
		}
		time.Sleep(20 * time.Millisecond)
	}

	deps := mcpserver.Deps{Store: s, Resolve: resolveViaCore}
	_, err = mcpserver.CallTool(ctx, deps, "resolve_loop", json.RawMessage(`{"id":"nope","evidence":"x"}`))
	if err == nil || !strings.Contains(err.Error(), "loop not found") {
		t.Fatalf("unknown id: %v", err)
	}
	out, err := mcpserver.CallTool(ctx, deps, "resolve_loop", json.RawMessage(`{"id":"`+open[0].ID+`","evidence":"sent"}`))
	if err != nil {
		t.Fatalf("valid id: %v", err)
	}
	if b, _ := json.Marshal(out); !bytes.Contains(b, []byte(`"ok":true`)) {
		t.Fatalf("out = %s", b)
	}
	if left, _ := loops.List(s, "open"); len(left) != 0 {
		t.Fatalf("loop still open: %+v", left)
	}
}

func TestResolveViaCoreDown(t *testing.T) {
	env(t)
	err := resolveViaCore(context.Background(), protocol.LoopSetStatus{ID: "x", Status: "resolved"})
	if !errors.Is(err, mcpserver.ErrCoreDown) {
		t.Fatalf("err = %v", err)
	}
}

type lockedBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuf) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}
func (l *lockedBuf) String() string { l.mu.Lock(); defer l.mu.Unlock(); return l.b.String() }

func TestMCPInstallUninstallCursor(t *testing.T) {
	_, user, _ := env(t)
	t.Setenv("PATH", t.TempDir())
	r := run(t, "", []string{"mcp", "install", "cursor"})
	if r.code != 0 {
		t.Fatalf("exit %d: %s", r.code, r.stderr)
	}
	p := filepath.Join(user, ".cursor", "mcp.json")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		MCPServers map[string]struct {
			Command string   `json:"command"`
			Args    []string `json:"args"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	e := doc.MCPServers["platynotch"]
	if e.Command != paths.HookBinary() || len(e.Args) != 1 || e.Args[0] != "mcp" {
		t.Fatalf("entry %+v", e)
	}
	if _, err := os.Lstat(paths.HookBinary()); err != nil {
		t.Fatalf("hook binary not linked: %v", err)
	}
	if r := run(t, "", []string{"mcp", "uninstall", "cursor"}); r.code != 0 {
		t.Fatalf("uninstall %d: %s", r.code, r.stderr)
	}
	b, _ = os.ReadFile(p)
	if strings.Contains(string(b), "platynotch") {
		t.Fatalf("not removed:\n%s", b)
	}
}

func TestMCPInstallClaudeCodeWithoutCLI(t *testing.T) {
	env(t)
	t.Setenv("PATH", t.TempDir())
	r := run(t, "", []string{"mcp", "install", "claude-code"})
	if r.code != 0 || !strings.Contains(r.stdout, "claude mcp add --scope user platynotch --") || !strings.Contains(r.stdout, "not run") {
		t.Fatalf("%d %q %q", r.code, r.stdout, r.stderr)
	}
}

func TestMCPInstallUsageErrors(t *testing.T) {
	env(t)
	for _, args := range [][]string{
		{"mcp", "install"},
		{"mcp", "install", "vscode"},
		{"mcp", "frob", "cursor"},
		{"mcp", "install", "cursor", "extra"},
	} {
		if r := run(t, "", args); r.code != 2 || !strings.Contains(r.stderr, "usage: notch mcp") {
			t.Errorf("%v: %d %q", args, r.code, r.stderr)
		}
	}
}
