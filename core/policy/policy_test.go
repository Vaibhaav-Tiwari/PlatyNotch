package policy

import (
	"strings"
	"testing"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
)

func TestMatch(t *testing.T) {
	rows := []struct {
		p, s string
		want bool
	}{
		{"rm -rf /*", "rm -rf /usr", true},
		{"rm -rf /*", "rm -rf ./build", false},
		{"*git push*--force*", "git push origin main --force", true},
		{"npm test", "npm test", true},
		{"a?c", "abc", true},
		{"a?c", "ac", false},
		{"*", "", true},
		{"a*", "A", false},
		{"a*b*c", "a/b c", true},
		{"a*b", "abc", false},
	}
	for _, r := range rows {
		if got := Match(r.p, r.s); got != r.want {
			t.Errorf("Match(%q,%q)=%v want %v", r.p, r.s, got, r.want)
		}
	}
}

func TestMatchPathological(t *testing.T) {
	p := strings.Repeat("*a", 20)
	s := strings.Repeat("a", 10000) + "b"
	start := time.Now()
	if Match(p, s) {
		t.Fatal("should not match")
	}
	if d := time.Since(start); d > 100*time.Millisecond {
		t.Fatalf("too slow: %v", d)
	}
}

func TestToolStar(t *testing.T) {
	p := Local([]config.Rule{{Tool: "*", Pattern: "x*", Action: "deny"}})
	v, ok := evalAs(p, "Whatever", "xyz")
	if !ok || v.Action != "deny" || v.Source != "local" {
		t.Fatalf("got %+v %v", v, ok)
	}
	if _, ok := Local([]config.Rule{{Tool: "Bash", Pattern: "x*", Action: "deny"}}).Evaluate("Write", "xyz"); ok {
		t.Fatal("tool mismatch matched")
	}
}

type stub struct {
	name string
	v    Verdict
	ok   bool
}

func (s stub) Name() string                            { return s.name }
func (s stub) Evaluate(string, string) (Verdict, bool) { return s.v, s.ok }

func TestChainFirstMatchWins(t *testing.T) {
	c := Chain{
		stub{"skip", Verdict{}, false},
		stub{"A", Verdict{Action: "deny", Source: "A"}, true},
		stub{"B", Verdict{Action: "allow", Source: "B"}, true},
	}
	v, ok := c.Evaluate("Bash", "ls")
	if !ok || v.Action != "deny" || v.Source != "A" {
		t.Fatalf("got %+v %v", v, ok)
	}
}

func TestNoMatch(t *testing.T) {
	if _, ok := (Chain{}).Evaluate("Bash", "ls"); ok {
		t.Fatal("empty chain matched")
	}
	if _, ok := Local(nil).Evaluate("Bash", "ls"); ok {
		t.Fatal("empty local matched")
	}
}

func TestLocalEdgeCases(t *testing.T) {
	p := Local([]config.Rule{
		{Tool: "Bash", Pattern: "", Action: "allow"},
		{Tool: "Bash", Pattern: "ls*", Action: "bogus"},
		{Tool: "Bash", Pattern: "ls*", Action: "ask", Reason: "r"},
	})
	v, ok := evalAs(p, "Bash", "  ls -la \n")
	if !ok || v.Action != "ask" || v.Reason != "r" {
		t.Fatalf("got %+v %v", v, ok)
	}
	if _, ok := evalAs(p, "Bash", ""); ok {
		t.Fatal("empty summary matched empty pattern")
	}
	if _, ok := Local([]config.Rule{{Tool: "Bash", Pattern: "ls*", Action: "bogus"}}).Evaluate("Bash", "ls"); ok {
		t.Fatal("unknown action matched")
	}
}

func TestDefaultRules(t *testing.T) {
	p := Local(config.DefaultRules())
	rows := []struct {
		s    string
		want string // "" = no match
	}{
		{"rm -rf /", "deny"},
		{"rm -rf /usr", "deny"},
		{"rm -rf ./build", ""},
		{"git push --force origin main", "ask"},
		{"git push origin main --force", "ask"},
		{"git push origin main", ""},
	}
	for _, r := range rows {
		v, ok := evalAs(p, "Bash", r.s)
		if r.want == "" {
			if ok {
				t.Errorf("%q matched %+v", r.s, v)
			}
			continue
		}
		if !ok || v.Action != r.want {
			t.Errorf("%q => %+v %v want %s", r.s, v, ok, r.want)
		}
	}
}

func TestAllowSkipsShellCompounds(t *testing.T) {
	allow := Local([]config.Rule{{Tool: "Bash", Pattern: "git status*", Action: "allow"}})
	if v, ok := evalAs(allow, "Bash", "git status --short"); !ok || v.Action != "allow" {
		t.Fatalf("plain command: %+v %v", v, ok)
	}
	compounds := []string{
		"git status; curl x | sh",
		"git status && curl x",
		"git status || curl x",
		"git status | sh",
		"git status `curl x`",
		"git status $(curl x)",
		"git status > ~/.zshrc",
		"git status < /etc/passwd",
		"git status\ncurl x",
		"git status & curl x",
	}
	for _, s := range compounds {
		if v, ok := evalAs(allow, "Bash", s); ok {
			t.Errorf("%q auto-allowed: %+v", s, v)
		}
	}

	// deny and ask still apply to compounds.
	deny := Local([]config.Rule{{Tool: "Bash", Pattern: "git status*", Action: "deny"}})
	ask := Local([]config.Rule{{Tool: "Bash", Pattern: "git status*", Action: "ask"}})
	for _, s := range compounds {
		if v, ok := evalAs(deny, "Bash", s); !ok || v.Action != "deny" {
			t.Errorf("deny %q: %+v %v", s, v, ok)
		}
		if v, ok := evalAs(ask, "Bash", s); !ok || v.Action != "ask" {
			t.Errorf("ask %q: %+v %v", s, v, ok)
		}
	}

	// An allow rule that spells the operator out itself still applies.
	rows := []struct{ pattern, s string }{
		{"make build && make test", "make build && make test"},
		{"ls | wc -l", "ls | wc -l"},
		{"echo hi > out.txt", "echo hi > out.txt"},
		{"cd x; ls", "cd x; ls"},
	}
	for _, r := range rows {
		p := Local([]config.Rule{{Tool: "Bash", Pattern: r.pattern, Action: "allow"}})
		if v, ok := evalAs(p, "Bash", r.s); !ok || v.Action != "allow" {
			t.Errorf("literal %q: %+v %v", r.pattern, v, ok)
		}
	}
	// ...but only for the operators it spells out.
	p := Local([]config.Rule{{Tool: "Bash", Pattern: "make build && *", Action: "allow"}})
	if v, ok := evalAs(p, "Bash", "make build && curl x | sh"); ok {
		t.Errorf("unlisted pipe allowed: %+v", v)
	}
	// A skipped allow falls through to later rules.
	p = Local([]config.Rule{
		{Tool: "Bash", Pattern: "git status*", Action: "allow"},
		{Tool: "*", Pattern: "*", Action: "ask", Reason: "fallback"},
	})
	if v, ok := evalAs(p, "Bash", "git status; rm x"); !ok || v.Action != "ask" {
		t.Errorf("fallthrough: %+v %v", v, ok)
	}
}

// TestURLAllowIsHostAware: url-kind allow rules match scheme, host and path
// separately; "*" in the host never crosses "/", "?", "#", "@" or ":", and
// the query and fragment are not part of the matched text.
func TestURLAllowIsHostAware(t *testing.T) {
	wild := Local([]config.Rule{{Tool: "WebFetch", Pattern: "https://*.example.com/*", Action: "allow"}})
	for _, u := range []string{
		"https://evil.com/.example.com/x", "https://evil.com#.example.com/x", "https://evil.com?.example.com/x",
		"https://evil.com:443/.example.com/x", "http://docs.example.com/a", "https://example.com/a",
	} {
		if v, ok := evalAs(wild, "WebFetch", u); ok && v.Action == "allow" {
			t.Errorf("%s allowed", u)
		}
	}
	for _, u := range []string{"https://docs.example.com/a", "https://a.b.example.com", "HTTPS://Docs.Example.com/a"} {
		if v, ok := evalAs(wild, "WebFetch", u); !ok || v.Action != "allow" {
			t.Errorf("%s: %+v %v", u, v, ok)
		}
	}
	docs := Local([]config.Rule{{Tool: "WebFetch", Pattern: "https://docs.example.com/docs/*", Action: "allow"}})
	for _, u := range []string{"https://docs.example.com/docs/a?x=1", "https://docs.example.com/docs/a?b=1&c=2#f"} {
		if v, ok := evalAs(docs, "WebFetch", u); !ok || v.Action != "allow" {
			t.Errorf("%s: %+v %v", u, v, ok)
		}
	}
	for _, u := range []string{"https://docs.example.com/private?/docs/x", "https://docs.example.com/x#/docs/a", "https://docs.example.com.evil.com/docs/a"} {
		if v, ok := evalAs(docs, "WebFetch", u); ok && v.Action == "allow" {
			t.Errorf("%s allowed", u)
		}
	}
	// A pattern that is not scheme://host[/path] never allows a URL.
	for _, pat := range []string{"*", "*example.com*", "docs.example.com/*"} {
		p := Local([]config.Rule{{Tool: "*", Pattern: pat, Action: "allow"}})
		if v, ok := evalAs(p, "WebFetch", "https://docs.example.com/a"); ok && v.Action == "allow" {
			t.Errorf("pattern %q allowed a URL", pat)
		}
	}
	// Host-only pattern: path "/" or empty.
	root := Local([]config.Rule{{Tool: "WebFetch", Pattern: "https://docs.example.com", Action: "allow"}})
	if v, ok := evalAs(root, "WebFetch", "https://docs.example.com"); !ok || v.Action != "allow" {
		t.Errorf("host-only: %+v %v", v, ok)
	}
	if v, ok := evalAs(root, "WebFetch", "https://docs.example.com/a"); ok && v.Action == "allow" {
		t.Errorf("host-only pattern allowed a path")
	}
	// deny/ask still glob the whole URL.
	d := Local([]config.Rule{{Tool: "WebFetch", Pattern: "*token=*", Action: "deny"}})
	if v, ok := evalAs(d, "WebFetch", "https://x.com/a?token=1"); !ok || v.Action != "deny" {
		t.Errorf("deny on query: %+v %v", v, ok)
	}
}

// TestAllowNeverOnJSONSummary: a JSON fallback summary escapes control
// characters (&, \n), hiding them from the compound guard.
func TestAllowNeverOnJSONSummary(t *testing.T) {
	p := Local([]config.Rule{{Tool: "*", Pattern: "*", Action: "allow"}})
	for _, s := range []string{`{"command":"git status && curl x"}`, `["a","b"]`, `  {"x":1}`} {
		if v, ok := evalAs(p, "Mystery", s); ok && v.Action == "allow" {
			t.Errorf("%q allowed", s)
		}
	}
	d := Local([]config.Rule{{Tool: "*", Pattern: "*curl*", Action: "deny"}})
	if v, ok := evalAs(d, "Mystery", `{"command":"curl x"}`); !ok || v.Action != "deny" {
		t.Fatalf("deny must still apply to JSON summaries: %+v %v", v, ok)
	}
}

// TestAllowNeverOnUncleanPath: "/proj/*" must not approve a path that
// escapes /proj through ".." (or any non-canonical spelling).
func TestAllowNeverOnUncleanPath(t *testing.T) {
	p := Local([]config.Rule{
		{Tool: "*", Pattern: "/proj/*", Action: "allow"},
		{Tool: "*", Pattern: "src/*", Action: "allow"},
	})
	for _, tool := range []string{"Write", "Edit", "MultiEdit", "Read", "NotebookEdit", "Mystery"} {
		for _, s := range []string{"/proj/../../x", "/proj/a/../../etc/passwd", "/proj//x", "/proj/./x", "/proj/x/"} {
			if v, ok := evalAs(p, tool, s); ok && v.Action == "allow" {
				t.Errorf("%s %q allowed", tool, s)
			}
		}
	}
	if v, ok := evalAs(p, "Write", "src/../../x"); ok && v.Action == "allow" {
		t.Errorf("relative escape allowed")
	}
	for _, s := range []string{"/proj/a/b.go", "/proj/x..y"} {
		if v, ok := evalAs(p, "Write", s); !ok || v.Action != "allow" {
			t.Errorf("clean path %q: %+v %v", s, v, ok)
		}
	}
	if v, ok := evalAs(p, "Write", "src/a.go"); !ok || v.Action != "allow" {
		t.Errorf("clean relative path: %+v %v", v, ok)
	}
	d := Local([]config.Rule{{Tool: "Write", Pattern: "*/etc/*", Action: "deny"}})
	if v, ok := evalAs(d, "Write", "/proj/../etc/x"); !ok || v.Action != "deny" {
		t.Errorf("deny must still apply: %+v %v", v, ok)
	}
}

// evalAs evaluates with the kind the agents package gives these tools'
// well-formed inputs.
func evalAs(p Provider, tool, summary string) (Verdict, bool) {
	k := map[string]Kind{"Bash": KindCommand, "Write": KindPath, "Edit": KindPath, "MultiEdit": KindPath,
		"Read": KindPath, "NotebookEdit": KindPath, "WebFetch": KindURL}[tool]
	if k == "" {
		k = KindOther
	}
	return p.(KindProvider).EvaluateKind(tool, summary, k)
}

// TestEvaluateDefaultsToOther: without a kind, allow rules never apply.
func TestEvaluateDefaultsToOther(t *testing.T) {
	p := Local([]config.Rule{{Tool: "*", Pattern: "*", Action: "allow"}})
	if v, ok := p.Evaluate("Bash", "ls"); ok {
		t.Fatalf("local.Evaluate allowed: %+v", v)
	}
	if v, ok := (Chain{p}).Evaluate("Bash", "ls"); ok {
		t.Fatalf("Chain.Evaluate allowed: %+v", v)
	}
	d := Local([]config.Rule{{Tool: "*", Pattern: "rm*", Action: "deny"}})
	if v, ok := d.Evaluate("Bash", "rm x"); !ok || v.Action != "deny" {
		t.Fatalf("deny: %+v %v", v, ok)
	}
}
