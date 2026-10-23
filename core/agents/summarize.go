package agents

import (
	"bytes"
	"encoding/json"
)

const summaryMax = 500

// Summarize renders a short human-readable description of a tool call for the
// approval card.
func Summarize(tool string, input json.RawMessage) string {
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
			return truncate(s)
		}
	}
	var buf bytes.Buffer
	if err := json.Compact(&buf, input); err != nil {
		return truncate(string(input))
	}
	return truncate(buf.String())
}

func truncate(s string) string {
	r := []rune(s)
	if len(r) <= summaryMax {
		return s
	}
	return string(r[:summaryMax]) + "…"
}
