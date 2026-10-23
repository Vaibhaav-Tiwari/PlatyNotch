package cli

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/discover"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/server"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/usage"
)

const (
	discoverEvery  = 60 * time.Second
	discoverWindow = 30 * time.Minute
	sweepEvery     = 30 * time.Second
)

// serve runs the core until SIGINT/SIGTERM or ctx is cancelled. Logs go to
// logs/core.log; stderr only carries a fatal startup error.
func (a *app) serve(ctx context.Context, args []string) int {
	if len(args) != 0 {
		return a.usageErr("serve", "takes no arguments")
	}
	if err := paths.EnsureHome(); err != nil {
		return a.fail("serve", err)
	}
	logFile, err := os.OpenFile(filepath.Join(paths.LogDir(), "core.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return a.fail("serve", err)
	}
	defer logFile.Close()
	logger := log.New(logFile, "", log.LstdFlags|log.Lmicroseconds)
	logf := logger.Printf

	cfg, err := config.Load()
	if err != nil {
		logf("config: %v (using defaults)", err)
	}

	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	mem, err := a.openMem(cfg)
	if err != nil {
		logf("memory: %v (memory off)", err)
	}
	if mem != nil {
		defer mem.Close()
	}

	srv, err := server.New(server.Options{
		Socket:     paths.Socket(),
		Edition:    a.edition,
		Config:     cfg,
		Memory:     mem,
		Extensions: a.extensions,
		Logf:       logf,
	})
	if err != nil {
		return a.fail("serve", err)
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var wg sync.WaitGroup
	every := func(d time.Duration, fn func()) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			fn()
			t := time.NewTicker(d)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					fn()
				}
			}
		}()
	}

	user := paths.UserHome()
	claudeProjects := filepath.Join(user, ".claude", "projects")
	codexSessions := filepath.Join(user, ".codex", "sessions")
	every(discoverEvery, func() {
		since := time.Now().Add(-discoverWindow)
		srv.UpsertSessions(discover.Claude(claudeProjects, since))
		srv.UpsertSessions(discover.Codex(codexSessions, since))
	})
	every(sweepEvery, srv.Sweep)
	wg.Add(1)
	go func() {
		defer wg.Done()
		usage.NewWatcher(paths.UsageFile(), codexSessions, srv.SetUsage).Run(ctx)
	}()

	logf("notch %s (%s) serving on %s", Version, a.edition, paths.Socket())
	err = srv.Serve(ctx)
	cancel()
	wg.Wait()
	if err != nil {
		logf("serve: %v", err)
		fmt.Fprintf(a.stderr, "notch serve: %v\n", err)
		return 1
	}
	logf("stopped")
	return 0
}

func (a *app) openMem(cfg config.Config) (memory.Service, error) {
	if a.openMemory == nil {
		return nil, nil
	}
	return a.openMemory(cfg)
}
