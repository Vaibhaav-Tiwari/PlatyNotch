package agents

import (
	"bytes"
	"encoding/json"
	"net/url"
	"path"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
)

const summaryMax = 500

// SummaryKind says what a policy summary is; policy applies allow rules only
// to the known kinds (command, path, url), never to KindOther.
type SummaryKind = policy.Kind

// PolicySummarizer is implemented by adapters whose permission events can
// carry a known summary kind. The adapter and event, never the tool name
// alone, decide the kind. Adapters without it get KindOther: no allow rule
// applies to their calls.
type PolicySummarizer interface {
	PolicySummary(event string, payload []byte) (text string, kind SummaryKind)
}

// PolicySummary is the summary policy evaluates for one hook event: the
// adapter's PolicySummary when it has one, else SummarizeFull's text with
// KindOther.
func PolicySummary(a Adapter, event string, payload []byte, c Common) (string, SummaryKind) {
	if ps, ok := a.(PolicySummarizer); ok {
		return ps.PolicySummary(event, payload)
	}
	s, _ := SummarizeFull(c.Tool, c.ToolInput)
	return s, policy.KindOther
}

// Summarize renders a short human-readable description of a tool call for the
// approval card: SummarizeFull cut to 500 runes plus "…". Never evaluate
// policy on it; a cut can hide a chained command.
func Summarize(tool string, input json.RawMessage) string {
	s, _ := SummarizeFull(tool, input)
	return truncate(s)
}

// Expected input keys per Claude Code tool kind. An input with any other key
// is KindOther: the extra argument may change what the call does.
var (
	commandKeys = keySet("command", "description", "timeout", "run_in_background")
	pathKeys    = keySet("file_path", "content", "old_string", "new_string", "replace_all", "edits",
		"offset", "limit", "notebook_path", "new_source", "cell_id", "cell_type", "edit_mode")
	urlKeys = keySet("url", "prompt")
)

func keySet(ks ...string) map[string]bool {
	m := make(map[string]bool, len(ks))
	for _, k := range ks {
		m[k] = true
	}
	return m
}

// SummarizeFull is the untruncated summary of a Claude Code style tool call
// and its kind. Bash gives its "command" (KindCommand); Write, Edit,
// MultiEdit and Read their "file_path" and NotebookEdit its "notebook_path"
// (KindPath); WebFetch its "url" (KindURL) when the URL is http(s), has no
// userinfo and a clean path. The input must be a JSON object with only the
// keys that tool kind expects (with an unexpected key the summary is the
// whole compacted input, so a human sees every argument). Anything else (unknown and MCP tools,
// unexpected keys, a missing field, string, non-object or invalid input) is
// the compacted input with KindOther.
func SummarizeFull(tool string, input json.RawMessage) (string, SummaryKind) {
	var key string
	var keys map[string]bool
	kind := policy.KindOther
	switch tool {
	case "Bash":
		kind, key, keys = policy.KindCommand, "command", commandKeys
	case "Write", "Edit", "MultiEdit", "Read":
		kind, key, keys = policy.KindPath, "file_path", pathKeys
	case "NotebookEdit":
		kind, key, keys = policy.KindPath, "notebook_path", pathKeys
	case "WebFetch":
		kind, key, keys = policy.KindURL, "url", urlKeys
	}
	if key != "" {
		var m map[string]any
		if json.Unmarshal(input, &m) == nil {
			if s, ok := m[key].(string); ok && s != "" {
				if !onlyKeys(m, keys) {
					// Show every argument: the extra one may matter.
					return compact(input), policy.KindOther
				}
				if kind == policy.KindURL && !cleanURL(s) {
					kind = policy.KindOther
				}
				return s, kind
			}
		}
	}
	return compact(input), policy.KindOther
}

// onlyKeys reports whether every key of m is in allowed.
func onlyKeys(m map[string]any, allowed map[string]bool) bool {
	for k := range m {
		if !allowed[k] {
			return false
		}
	}
	return true
}

// cleanURL accepts http(s) URLs with a host, no userinfo and a canonical path.
func cleanURL(s string) bool {
	u, err := url.Parse(s)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.Host == "" || u.Opaque != "" {
		return false
	}
	return u.Path == "" || path.Clean(u.Path) == u.Path
}

// ShellSummary is the policy summary of a shell-execution event whose
// payload carries the command at the top level (Cursor). It is KindCommand
// only when that command is non-empty and toolInput is absent or an object
// with only Bash's keys whose "command", if any, is the same command.
func ShellSummary(command string, toolInput json.RawMessage) (string, SummaryKind) {
	if command == "" {
		return compact(toolInput), policy.KindOther
	}
	if len(bytes.TrimSpace(toolInput)) == 0 || string(bytes.TrimSpace(toolInput)) == "null" {
		return command, policy.KindCommand
	}
	var m map[string]any
	if json.Unmarshal(toolInput, &m) != nil || !onlyKeys(m, commandKeys) {
		return command, policy.KindOther
	}
	if c, present := m["command"]; present {
		if s, ok := c.(string); !ok || s != command {
			return command, policy.KindOther
		}
	}
	return command, policy.KindCommand
}

func compact(input json.RawMessage) string {
	var buf bytes.Buffer
	if err := json.Compact(&buf, input); err != nil {
		return string(input)
	}
	return buf.String()
}

func truncate(s string) string {
	r := []rune(s)
	if len(r) <= summaryMax {
		return s
	}
	return string(r[:summaryMax]) + "…"
}
