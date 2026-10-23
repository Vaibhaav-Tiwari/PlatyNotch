// Package policy evaluates approval rules against a pending tool call.
package policy

import (
	"strings"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
)

// Verdict is a policy decision. Action is "allow", "deny" or "ask".
type Verdict struct {
	Action string
	Reason string
	Source string
}

// Provider decides on a tool call; ok is false when it has no opinion.
type Provider interface {
	Name() string
	Evaluate(tool, summary string) (Verdict, bool)
}

// Chain evaluates providers in order; the first match wins.
type Chain []Provider

func (c Chain) Evaluate(tool, summary string) (Verdict, bool) {
	for _, p := range c {
		if v, ok := p.Evaluate(tool, summary); ok {
			return v, true
		}
	}
	return Verdict{}, false
}

type local struct{ rules []config.Rule }

// Local returns a provider backed by config rules (Source "local").
// Rules are tried in order; empty patterns and unknown actions are skipped,
// and so is an allow rule when the summary contains a shell control sequence
// the pattern does not contain literally (see config.Rule).
func Local(rules []config.Rule) Provider {
	return local{rules: append([]config.Rule(nil), rules...)}
}

func (local) Name() string { return "local" }

func (l local) Evaluate(tool, summary string) (Verdict, bool) {
	summary = strings.TrimSpace(summary)
	for _, r := range l.rules {
		switch r.Action {
		case "allow", "deny", "ask":
		default:
			continue
		}
		if r.Pattern == "" || (r.Tool != "*" && r.Tool != tool) {
			continue
		}
		if r.Action == "allow" && compoundBeyond(r.Pattern, summary) {
			continue
		}
		if Match(r.Pattern, summary) {
			return Verdict{Action: r.Action, Reason: r.Reason, Source: "local"}, true
		}
	}
	return Verdict{}, false
}

// shellControl are sequences that chain, substitute or redirect commands.
// "&" covers "&&" and backgrounding; "|" covers "||"; "\r" is treated like
// a newline.
var shellControl = []string{";", "&&", "||", "|", "&", "`", "$(", ">", "<", "\n", "\r"}

// compoundBeyond reports whether summary uses a shell control sequence that
// pattern does not spell out literally, so an allow rule written for one
// command cannot approve a chain such as `git status && curl x | sh`.
func compoundBeyond(pattern, summary string) bool {
	for _, op := range shellControl {
		if strings.Contains(summary, op) && !strings.Contains(pattern, op) {
			return true
		}
	}
	return false
}

// Match reports whether s matches the whole of pattern. '*' matches any run
// of characters (including '/' and spaces), '?' matches one character;
// matching is case-sensitive. Runs in O(len(pattern)*len(s)) worst case.
func Match(pattern, s string) bool {
	p, t := []rune(pattern), []rune(s)
	pi, ti := 0, 0
	star, mark := -1, 0
	for ti < len(t) {
		switch {
		case pi < len(p) && p[pi] == '*':
			star, mark = pi, ti
			pi++
		case pi < len(p) && (p[pi] == '?' || p[pi] == t[ti]):
			pi++
			ti++
		case star >= 0:
			mark++
			ti = mark
			pi = star + 1
		default:
			return false
		}
	}
	for pi < len(p) && p[pi] == '*' {
		pi++
	}
	return pi == len(p)
}
