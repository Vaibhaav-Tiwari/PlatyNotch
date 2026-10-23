package cli

import (
	"context"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/mcpserver"
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

	src := &memSource{logger: logger}
	defer src.Close()
	deps := mcpserver.Deps{Resolve: resolveViaCore, Open: src.get}

	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger.Printf("mcp server started")
	if err := mcpserver.Serve(ctx, a.stdin, a.stdout, deps); err != nil {
		logger.Printf("mcp server: %v", err)
		return 1
	}
	logger.Printf("mcp server stopped")
	return 0
}

const resolveTimeout = 5 * time.Second

// resolveViaCore sends loop.set_status to the running core as the cli role.
func resolveViaCore(_ context.Context, s protocol.LoopSetStatus) error {
	c, err := dialCore()
	if err != nil {
		return mcpserver.ErrCoreDown
	}
	defer c.Close()
	return c.sendAwaitReply(protocol.TypeLoopSetStatus, "r", s, resolveTimeout)
}
