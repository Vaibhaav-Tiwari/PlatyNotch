// Package policy evaluates approval rules against a pending tool call.
package policy

import (
	"path"
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

// Kind says what a summary is. The agent adapter decides it from the hook
// event and payload (see agents.PolicySummary), never from the tool name.
type Kind string

const (
	KindCommand Kind = "command" // a known shell tool's command
	KindPath    Kind = "path"    // a known file tool's path
	KindURL     Kind = "url"     // WebFetch's URL
	KindOther   Kind = "other"   // anything else, including fallbacks
)

// KindProvider is implemented by providers that take the summary's kind
// into account.
type KindProvider interface {
	EvaluateKind(tool, summary string, kind Kind) (Verdict, bool)
}

// Chain evaluates providers in order; the first match wins.
type Chain []Provider

// Evaluate is EvaluateKind with KindOther: no local allow rule applies.
func (c Chain) Evaluate(tool, summary string) (Verdict, bool) {
	return c.EvaluateKind(tool, summary, KindOther)
}

// EvaluateKind passes kind to providers implementing KindProvider.
func (c Chain) EvaluateKind(tool, summary string, kind Kind) (Verdict, bool) {
	for _, p := range c {
		var v Verdict
		var ok bool
		if kp, isKP := p.(KindProvider); isKP {
			v, ok = kp.EvaluateKind(tool, summary, kind)
		} else {
			v, ok = p.Evaluate(tool, summary)
		}
		if ok {
			return v, true
		}
	}
	return Verdict{}, false
}

type local struct{ rules []config.Rule }

// Local returns a provider backed by config rules (Source "local").
// Rules are tried in order; empty patterns and unknown actions are skipped,
// and so is an allow rule when the summary's kind is not command, path or
// url (see EvaluateKind), when the summary contains a shell control sequence
// the pattern does not contain literally (see config.Rule), or when the
// summary looks truncated (ends in TruncationMark), is a JSON fallback
// (starts with '{' or '['; JSON escaping hides control operators), or is a
// file path that is not canonical (see uncleanPath). Callers pass the
// untruncated summary (agents.SummarizeFull); the truncation check is a
// defensive backstop.
func Local(rules []config.Rule) Provider {
	return local{rules: append([]config.Rule(nil), rules...)}
}

func (local) Name() string { return "local" }

// Evaluate is EvaluateKind with KindOther: deny and ask rules apply, allow
// rules never do. Callers that know the kind use EvaluateKind.
func (l local) Evaluate(tool, summary string) (Verdict, bool) {
	return l.EvaluateKind(tool, summary, KindOther)
}

// EvaluateKind never applies an allow rule unless kind is command, path or
// url: a fallback summary (unknown or MCP tool, JSON or string input) can
// hide arguments and escaped control operators from the pattern.
func (l local) EvaluateKind(tool, summary string, kind Kind) (Verdict, bool) {
	summary = strings.TrimSpace(summary)
	noAllow := (kind != KindCommand && kind != KindPath && kind != KindURL) ||
		strings.HasSuffix(summary, TruncationMark) ||
		strings.HasPrefix(summary, "{") || strings.HasPrefix(summary, "[") ||
		uncleanPath(tool, summary)
	for _, r := range l.rules {
		switch r.Action {
		case "allow", "deny", "ask":
		default:
			continue
		}
		if r.Pattern == "" || (r.Tool != "*" && r.Tool != tool) {
			continue
		}
		if r.Action == "allow" && (noAllow || compoundBeyond(r.Pattern, summary)) {
			continue
		}
		if Match(r.Pattern, summary) {
			return Verdict{Action: r.Action, Reason: r.Reason, Source: "local"}, true
		}
	}
	return Verdict{}, false
}

// TruncationMark ends a summary that agents.Summarize cut short. What was cut
// may hold a chained command, so no allow rule applies to such a summary.
const TruncationMark = "…"

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

// fileTools take a path as their summary.
var fileTools = map[string]bool{"Write": true, "Edit": true, "MultiEdit": true, "Read": true, "NotebookEdit": true}

// uncleanPath reports whether summary is a path (a file tool's summary, or
// any summary that looks like a path) that is not in canonical form or has a
// ".." segment, so "/proj/*" cannot approve "/proj/../../x". Over-strict on
// purpose: "./a", "a//b" and "a/" fall through to a human.
func uncleanPath(tool, summary string) bool {
	if !fileTools[tool] && !looksLikePath(summary) {
		return false
	}
	if path.Clean(summary) != summary {
		return true
	}
	for _, seg := range strings.Split(summary, "/") {
		if seg == ".." {
			return true
		}
	}
	return false
}

func looksLikePath(s string) bool {
	if strings.ContainsAny(s, " \t") {
		return false
	}
	for _, p := range []string{"/", "~/", "./", "../"} {
		if strings.HasPrefix(s, p) {
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
