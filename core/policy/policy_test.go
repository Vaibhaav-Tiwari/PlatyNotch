package policy

import (
	"strings"
	"testing"
	"time"

	"github.com/platynotch/platynotch/core/config"
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
	v, ok := p.Evaluate("Whatever", "xyz")
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
	v, ok := p.Evaluate("Bash", "  ls -la \n")
	if !ok || v.Action != "ask" || v.Reason != "r" {
		t.Fatalf("got %+v %v", v, ok)
	}
	if _, ok := p.Evaluate("Bash", ""); ok {
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
		v, ok := p.Evaluate("Bash", r.s)
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
