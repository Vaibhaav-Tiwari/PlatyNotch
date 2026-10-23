package all

import (
	"testing"

	"github.com/platynotch/platynotch/core/agents"
)

func TestAllRegistersSix(t *testing.T) {
	want := []string{"claude-code", "codex", "cursor", "gemini", "opencode", "qwen"}
	got := agents.All()
	if len(got) != len(want) {
		t.Fatalf("got %d adapters, want %d", len(got), len(want))
	}
	for i, a := range got {
		if a.ID() != want[i] {
			t.Errorf("adapter %d: got %q want %q", i, a.ID(), want[i])
		}
	}
}
