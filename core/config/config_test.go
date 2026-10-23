package config

import (
	"os"

	"github.com/platynotch/platynotch/core/paths"
	"path/filepath"
	"strconv"
	"testing"
)

func TestConfigDefaults(t *testing.T) {
	cfg, err := LoadFile(filepath.Join(t.TempDir(), "missing.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Approvals.Enabled || cfg.Approvals.TimeoutSeconds != 100 ||
		!cfg.Approvals.Agents["claude-code"] || cfg.Memory.Enabled ||
		cfg.Memory.Embedder.Name != "none" {
		t.Fatalf("bad defaults: %+v", cfg)
	}
	if !cfg.ApprovalsOn("claude-code") || cfg.ApprovalsOn("codex") {
		t.Fatal("ApprovalsOn wrong")
	}
}

func TestConfigSaveIsOwnerOnly(t *testing.T) {
	t.Setenv("PLATYNOTCH_HOME", t.TempDir())
	if err := Save(Default()); err != nil {
		t.Fatal(err)
	}
	st, err := osStat(t)
	if err != nil {
		t.Fatal(err)
	}
	if m := st.Mode().Perm(); m != 0o600 {
		t.Fatalf("mode %o", m)
	}
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
}

func TestSecretEnv(t *testing.T) {
	t.Setenv("X", "abc")
	if v, err := Secret("env:X"); err != nil || v != "abc" {
		t.Fatalf("got %q, %v", v, err)
	}
	if _, err := Secret("bogus:1"); err == nil {
		t.Fatal("want error")
	}
	if v, err := Secret(""); err != nil || v != "" {
		t.Fatalf("empty ref: %q %v", v, err)
	}
}

func osStat(t *testing.T) (os.FileInfo, error) {
	t.Helper()
	return os.Stat(paths.Config())
}

// The hook client waits timeout+2 s; agents kill hooks at 120 s, so the
// timeout is clamped to [10, 115] (non-positive still means the default).
func TestTimeoutClamped(t *testing.T) {
	for _, tc := range []struct{ in, want int }{
		{0, 100}, {-5, 100}, {1, 10}, {10, 10}, {60, 60}, {115, 115}, {116, 115}, {600, 115},
	} {
		p := filepath.Join(t.TempDir(), "config.json")
		b := []byte(`{"approvals":{"enabled":true,"timeout_seconds":` + strconv.Itoa(tc.in) + `}}`)
		if err := os.WriteFile(p, b, 0o600); err != nil {
			t.Fatal(err)
		}
		cfg, err := LoadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if cfg.Approvals.TimeoutSeconds != tc.want {
			t.Errorf("timeout %d: got %d, want %d", tc.in, cfg.Approvals.TimeoutSeconds, tc.want)
		}
	}
}
