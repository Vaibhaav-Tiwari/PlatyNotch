package agents

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

type fake struct{ id string }

func (f fake) ID() string                                          { return f.id }
func (f fake) Name() string                                        { return f.id }
func (f fake) Detect() bool                                        { return false }
func (f fake) ConfigPath() string                                  { return "" }
func (f fake) InstallHooks(string) (bool, error)                   { return false, nil }
func (f fake) UninstallHooks() (bool, error)                       { return false, nil }
func (f fake) HooksInstalled() (bool, error)                       { return false, nil }
func (f fake) DeriveState(string, []byte) (protocol.State, bool)   { return "", false }
func (f fake) ParseCommon(string, []byte) Common                   { return Common{} }
func (f fake) Approvals() ApprovalSupport                          { return ApprovalsNone }
func (f fake) IsPermissionEvent(string) bool                       { return false }
func (f fake) FormatDecision(string, protocol.HookDecision) []byte { return nil }

func TestRegistry(t *testing.T) {
	Register(fake{"zz-b"})
	Register(fake{"zz-a"})
	if _, ok := Get("zz-a"); !ok {
		t.Fatal("zz-a not found")
	}
	if _, ok := Get("nope"); ok {
		t.Fatal("unexpected")
	}
	var ids []string
	for _, a := range All() {
		ids = append(ids, a.ID())
	}
	for i := 1; i < len(ids); i++ {
		if ids[i-1] > ids[i] {
			t.Fatalf("not sorted: %v", ids)
		}
	}
}

func TestSummarize(t *testing.T) {
	cases := []struct{ tool, in, want string }{
		{"Bash", `{"command":"rm -rf build"}`, "rm -rf build"},
		{"Write", `{"file_path":"/a/b.go","content":"x"}`, "/a/b.go"},
		{"Edit", `{"file_path":"/a/c.go"}`, "/a/c.go"},
		{"MultiEdit", `{"file_path":"/a/d.go"}`, "/a/d.go"},
		{"Read", `{"file_path":"/a/e.go"}`, "/a/e.go"},
		{"WebFetch", `{"url":"https://x.dev","prompt":"p"}`, "https://x.dev"},
		{"Mystery", `{"a": 1,  "b": "x"}`, `{"a":1,"b":"x"}`},
	}
	for _, c := range cases {
		if got := Summarize(c.tool, json.RawMessage(c.in)); got != c.want {
			t.Errorf("%s: got %q want %q", c.tool, got, c.want)
		}
	}
	long := `{"k":"` + strings.Repeat("é", 600) + `"}`
	got := Summarize("Mystery", json.RawMessage(long))
	if r := []rune(got); len(r) != 501 || r[500] != '…' {
		t.Errorf("truncation: %d runes", len(r))
	}
}
