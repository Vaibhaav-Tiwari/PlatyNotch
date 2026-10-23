package agents

import (
	"encoding/json"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
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
		{"NotebookEdit", `{"notebook_path":"/a/n.ipynb"}`, "/a/n.ipynb"},
		{"Shell", `{"command":"a && b"}`, `{"command":"a && b"}`},
		{"Bash", `{"command":"ls","script":"rm -rf ~"}`, `{"command":"ls","script":"rm -rf ~"}`},
		{"Mystery", `{"command":42}`, `{"command":42}`},
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

func TestSummarizeFullNeverTruncates(t *testing.T) {
	cmd := "git status " + strings.Repeat("x", 520) + " ; curl x | sh"
	in := json.RawMessage(`{"command":"` + cmd + `"}`)
	if got, k := SummarizeFull("Bash", in); got != cmd || k != policy.KindCommand {
		t.Fatalf("SummarizeFull truncated: %d runes", len([]rune(got)))
	}
	if got := Summarize("Bash", in); got == cmd || !strings.HasSuffix(got, "…") {
		t.Fatalf("Summarize did not truncate")
	}
	if got, k := SummarizeFull("Mystery", json.RawMessage(`{"a": 1}`)); got != `{"a":1}` || k != policy.KindOther {
		t.Fatalf("%q %s", got, k)
	}
	for _, c := range []struct {
		tool, in string
		kind     policy.Kind
	}{
		{"Bash", `{"command":"ls","description":"d","timeout":5,"run_in_background":false}`, policy.KindCommand},
		{"Shell", `{"command":"ls"}`, policy.KindOther},
		{"run_terminal_cmd", `{"command":"ls"}`, policy.KindOther},
		{"Bash", `{"command":"ls","script":"rm -rf ~"}`, policy.KindOther},
		{"Write", `{"file_path":"/a"}`, policy.KindPath},
		{"Edit", `{"file_path":"/a","old_string":"x","new_string":"y","replace_all":true}`, policy.KindPath},
		{"Read", `{"file_path":"/proj/a","also":"/etc/shadow"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/a","prompt":"p","method":"POST","body":"b"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://u:p@x/a"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/a/../b"}`, policy.KindOther},
		{"WebFetch", `{"url":"file:///etc/passwd"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x"}`, policy.KindURL},
		{"WebFetch", `{"url":"https://docs.example.com/docs/..\\private"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://docs.example.com/docs/\\..\\..\\private"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/docs/%2e%2e/private"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/docs/%2E./private"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/docs%2fprivate"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/docs%5Cprivate"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/{%2e%2e/private"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/a%2E%2e?q=1"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/a?next=%2Fb"}`, policy.KindURL},
		{"WebFetch", `{"url":" https://x/a"}`, policy.KindOther},
		{"WebFetch", `{"url":"https://x/a\n"}`, policy.KindOther},
		{"Read", `{"file_path":" /proj/a"}`, policy.KindOther},
		{"Write", `{"file_path":"/proj/a ","content":"x"}`, policy.KindOther},
		{"Bash", `{"command":" ls "}`, policy.KindCommand},
		{"NotebookEdit", `{"notebook_path":"/a.ipynb"}`, policy.KindPath},
		{"Bash", `"{\"command\":\"ls\"}"`, policy.KindOther},
		{"Bash", `{"cmd":"ls"}`, policy.KindOther},
		{"Bash", `not json`, policy.KindOther},
		{"mcp__x__y", `{"command":"ls","path":"/etc/shadow"}`, policy.KindOther},
	} {
		if _, k := SummarizeFull(c.tool, json.RawMessage(c.in)); k != c.kind {
			t.Errorf("%s %s: kind %s want %s", c.tool, c.in, k, c.kind)
		}
	}
	for _, c := range []struct {
		cmd, input string
		kind       policy.Kind
	}{
		{"git status", ``, policy.KindCommand},
		{"git status", `null`, policy.KindCommand},
		{"git status", `{"command":"git status"}`, policy.KindCommand},
		{"git status", `{"command":"rm -rf ~"}`, policy.KindOther},
		{"git status", `{"command":"git status","script":"x"}`, policy.KindOther},
		{"git status", `"git status"`, policy.KindOther},
		{"", `{"command":"git status"}`, policy.KindOther},
	} {
		if _, k := ShellSummary(c.cmd, json.RawMessage(c.input)); k != c.kind {
			t.Errorf("ShellSummary(%q, %s) kind %s want %s", c.cmd, c.input, k, c.kind)
		}
	}
	if got := Summarize("mcp__x__y", json.RawMessage(`{"command":"ls","path":"/etc/shadow"}`)); !strings.Contains(got, "/etc/shadow") {
		t.Errorf("display hides arguments: %q", got)
	}
}
