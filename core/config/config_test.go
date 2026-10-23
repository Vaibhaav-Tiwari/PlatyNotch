package config

import (
	"os"

	"github.com/platynotch/platynotch/core/paths"
	"path/filepath"
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
