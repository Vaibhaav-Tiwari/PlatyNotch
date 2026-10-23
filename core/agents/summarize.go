package agents

import (
	"bytes"
	"encoding/json"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/policy"
)

const summaryMax = 500

// SummaryKind says what a summary is; policy applies allow rules only to
// the known kinds (command, path, url), never to KindOther.
type SummaryKind = policy.Kind

// Summarize renders a short human-readable description of a tool call for the
// approval card: SummarizeFull cut to 500 runes plus "…". Never evaluate
// policy on it; a cut can hide a chained command.
func Summarize(tool string, input json.RawMessage) string {
	s, _ := SummarizeFull(tool, input)
	return truncate(s)
}

// SummarizeFull is the untruncated summary that policy rules are evaluated
// against, and its kind. Only known tools get a known kind, from one field:
// shell tools (Bash, Cursor's Shell, run_terminal_cmd) their "command";
// Write/Edit/MultiEdit/Read their "file_path" and NotebookEdit its
// "notebook_path"; WebFetch its "url". Everything else (unknown and MCP
// tools, a missing field, string, non-object or invalid input) is the
// compacted input with KindOther.
func SummarizeFull(tool string, input json.RawMessage) (string, SummaryKind) {
	kind := policy.KindFor(tool)
	key := ""
	switch kind {
	case policy.KindCommand:
		key = "command"
	case policy.KindPath:
		key = "file_path"
		if tool == "NotebookEdit" {
			key = "notebook_path"
		}
	case policy.KindURL:
		key = "url"
	}
	if key != "" {
		var m map[string]any
		if json.Unmarshal(input, &m) == nil {
			if s, ok := m[key].(string); ok && s != "" {
				return s, kind
			}
		}
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, input); err != nil {
		return string(input), policy.KindOther
	}
	return buf.String(), policy.KindOther
}

func truncate(s string) string {
	r := []rune(s)
	if len(r) <= summaryMax {
		return s
	}
	return string(r[:summaryMax]) + "…"
}
