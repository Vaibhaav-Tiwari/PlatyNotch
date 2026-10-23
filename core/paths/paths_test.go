package paths

import (
	"path/filepath"
	"testing"
)

func TestPathsOverride(t *testing.T) {
	t.Setenv("PLATYNOTCH_HOME", "/tmp/x")
	t.Setenv("PLATYNOTCH_SOCKET", "")
	if got := Socket(); got != "/tmp/x/notch.sock" {
		t.Fatal(got)
	}
	if got := HookBinary(); got != "/tmp/x/bin/notch" {
		t.Fatal(got)
	}
	t.Setenv("PLATYNOTCH_SOCKET", "/tmp/s.sock")
	if Socket() != "/tmp/s.sock" {
		t.Fatal("socket override")
	}
	t.Setenv("PLATYNOTCH_USER_HOME", "/tmp/u")
	if UserHome() != "/tmp/u" {
		t.Fatal("user home override")
	}
}

func TestEnsureHome(t *testing.T) {
	h := filepath.Join(t.TempDir(), "h")
	t.Setenv("PLATYNOTCH_HOME", h)
	if err := EnsureHome(); err != nil {
		t.Fatal(err)
	}
}
