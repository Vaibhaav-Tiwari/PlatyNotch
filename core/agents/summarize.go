package agents

import (
	"bytes"
	"encoding/json"
)

const summaryMax = 500

// Summarize renders a short human-readable description of a tool call for the
// approval card: SummarizeFull cut to 500 runes plus "…". Never evaluate
// policy on it; a cut can hide a chained command.
func Summarize(tool string, input json.RawMessage) string {
	return truncate(SummarizeFull(tool, input))
}

// SummarizeFull is the untruncated summary (the whole command, path or URL,
// else the compacted input) that policy rules are evaluated against.
func SummarizeFull(tool string, input json.RawMessage) string {
	var m map[string]any
	_ = json.Unmarshal(input, &m)
	key := ""
	switch tool {
	case "Bash":
		key = "command"
	case "Write", "Edit", "MultiEdit", "Read":
		key = "file_path"
	case "WebFetch":
		key = "url"
	}
	if key != "" {
		if s, ok := m[key].(string); ok && s != "" {
			return s
		}
	}
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
