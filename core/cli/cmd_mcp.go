package cli

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/mcpserver"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// mcp runs the stdio MCP server that AI apps launch. stdout carries the
// protocol, so every log line goes to logs/mcp.log. Memory is read straight
// from a read-only memory.db; loop changes go through the core socket.
// `mcp install|uninstall <client>` registers the server with an AI client.
func (a *app) mcp(ctx context.Context, args []string) int {
	if len(args) != 0 {
		return a.mcpInstall(ctx, args)
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

// mcpInstall handles `mcp install|uninstall <client>`. The registered command
// is the stable hook binary path, so it survives app moves and updates.
func (a *app) mcpInstall(ctx context.Context, args []string) int {
	if args[0] != "install" && args[0] != "uninstall" {
		return a.usageErr("mcp", "unknown subcommand "+args[0])
	}
	if len(args) != 2 {
		return a.usageErr("mcp", "expected one client")
	}
	client := args[1]
	if !slices.Contains(mcpserver.Clients, client) {
		return a.usageErr("mcp", fmt.Sprintf("unknown client %q (one of: %s)", client, strings.Join(mcpserver.Clients, ", ")))
	}
	var msg string
	var err error
	if args[0] == "install" {
		var bin string
		if bin, err = ensureHookBinary(); err != nil {
			return a.fail("mcp", err)
		}
		msg, err = mcpserver.Install(ctx, client, bin, mcpserver.ExecRunner)
	} else {
		msg, err = mcpserver.Uninstall(ctx, client, mcpserver.ExecRunner)
	}
	if err != nil {
		return a.fail("mcp", err)
	}
	fmt.Fprintln(a.stdout, msg)
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
