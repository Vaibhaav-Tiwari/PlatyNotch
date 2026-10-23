package cli

import (
	"log"
	"os"
	"sync"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
)

// closeDelay is how long a replaced store stays open so calls already using
// it can finish.
const closeDelay = 30 * time.Second

// memSource hands the MCP server the current read-only store and embedder. It
// re-checks the config file and memory.db on every call and reopens only when
// either changed, so turning memory on (or recreating the database) is picked
// up by a server that stays running.
type memSource struct {
	logger *log.Logger

	mu     sync.Mutex
	cfgKey [2]int64 // config mtime (ns), size; zeros when absent
	dbInfo os.FileInfo
	st     *store.Store
	emb    provider.Embedder
	init   bool
}

func (m *memSource) get() (*store.Store, provider.Embedder, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	var key [2]int64
	if fi, err := os.Stat(paths.Config()); err == nil {
		key = [2]int64{fi.ModTime().UnixNano(), fi.Size()}
	}
	dbi, dberr := os.Stat(paths.MemoryDB())
	if dberr != nil {
		dbi = nil
	}
	if m.init && key == m.cfgKey && sameFile(dbi, m.dbInfo) {
		return m.st, m.emb, nil
	}

	m.release()
	m.init, m.cfgKey, m.dbInfo = true, key, dbi

	cfg, err := config.Load()
	if err != nil {
		m.logger.Printf("config: %v (using defaults)", err)
	}
	if !cfg.Memory.Enabled || dbi == nil {
		m.logger.Printf("memory off (enabled=%v, db present=%v)", cfg.Memory.Enabled, dbi != nil)
		return nil, nil, nil
	}
	st, err := store.Open(paths.MemoryDB(), true)
	if err != nil {
		m.init = false // retry on the next call
		m.logger.Printf("memory.db: %v", err)
		return nil, nil, err
	}
	m.st = st
	if emb, err := provider.NewEmbedder(cfg.Memory.Embedder); err != nil {
		m.logger.Printf("embedder: %v (keyword search only)", err)
	} else {
		m.emb = emb
	}
	m.logger.Printf("memory on")
	return m.st, m.emb, nil
}

func sameFile(a, b os.FileInfo) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return os.SameFile(a, b)
}

// release drops the cached store, closing it after closeDelay.
func (m *memSource) release() {
	if m.st != nil {
		st := m.st
		time.AfterFunc(closeDelay, func() { st.Close() })
	}
	m.st, m.emb = nil, nil
}

// Close closes the cached store now.
func (m *memSource) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.st != nil {
		m.st.Close()
	}
	m.st, m.emb, m.init = nil, nil, false
}
