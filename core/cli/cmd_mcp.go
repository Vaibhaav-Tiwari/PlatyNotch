package cli

import (
	"context"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/mcpserver"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// mcp runs the stdio MCP server that AI apps launch. stdout carries the
// protocol, so every log line goes to logs/mcp.log. Memory is read straight
// from a read-only memory.db; loop changes go through the core socket.
func (a *app) mcp(ctx context.Context, args []string) int {
	if len(args) != 0 {
		return a.usageErr("mcp", "takes no arguments")
	}
	if err := paths.EnsureHome(); err != nil {
		return a.fail("mcp", err)
	}
	logFile, err := os.OpenFile(filepath.Join(paths.LogDir(), "mcp.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return a.fail("mcp", err)
	}
	defer logFile.Close()
	logger := log.New(logFile, "", log.LstdFlags|log.Lmicroseconds)

	cfg, err := config.Load()
	if err != nil {
		logger.Printf("config: %v (using defaults)", err)
	}
	deps := mcpserver.Deps{Resolve: resolveViaCore}
	if cfg.Memory.Enabled {
		if _, statErr := os.Stat(paths.MemoryDB()); statErr == nil {
			st, err := store.Open(paths.MemoryDB(), true)
			if err != nil {
				logger.Printf("memory.db: %v (memory off)", err)
			} else {
				defer st.Close()
				deps.Store = st
			}
		} else {
			logger.Printf("memory.db: %v (memory off)", statErr)
		}
		if emb, err := provider.NewEmbedder(cfg.Memory.Embedder); err != nil {
			logger.Printf("embedder: %v (keyword search only)", err)
		} else if emb != nil {
			deps.Embedder = emb
		}
	}

	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger.Printf("mcp server started (memory %v)", deps.Store != nil)
	if err := mcpserver.Serve(ctx, a.stdin, a.stdout, deps); err != nil {
		logger.Printf("mcp server: %v", err)
		return 1
	}
	logger.Printf("mcp server stopped")
	return 0
}

// resolveViaCore sends loop.set_status to the running core as the cli role.
func resolveViaCore(_ context.Context, s protocol.LoopSetStatus) error {
	c, err := dialCore()
	if err != nil {
		return mcpserver.ErrCoreDown
	}
	defer c.Close()
	return c.sendConfirmed(protocol.TypeLoopSetStatus, s)
}
