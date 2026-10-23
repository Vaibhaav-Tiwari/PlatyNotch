package ingest

import (
	"strings"
	"unicode"
)

// NewText returns the lines of cur that are not present in prev (set
// difference, order kept). Blank lines survive only as single paragraph
// breaks between emitted lines.
func NewText(prev, cur string) string {
	seen := map[string]bool{}
	for _, l := range strings.Split(prev, "\n") {
		seen[strings.TrimSpace(l)] = true
	}
	var out []string
	pendingBlank := false
	for _, l := range strings.Split(cur, "\n") {
		t := strings.TrimSpace(l)
		if t == "" {
			pendingBlank = len(out) > 0
			continue
		}
		if seen[t] {
			continue
		}
		if pendingBlank {
			out = append(out, "")
			pendingBlank = false
		}
		out = append(out, l)
	}
	return strings.Join(out, "\n")
}

// Chunk splits s into pieces of at most size runes, consecutive pieces
// overlapping by about overlap runes. It breaks on a paragraph, else a
// sentence end, else whitespace, else hard-cuts.
func Chunk(s string, size, overlap int) []string {
	r := []rune(s)
	n := len(r)
	if size <= 0 {
		return nil
	}
	if overlap < 0 || overlap >= size/2 {
		overlap = size / 4
	}
	var out []string
	add := func(a, b int) {
		if strings.TrimSpace(string(r[a:b])) != "" {
			out = append(out, string(r[a:b]))
		}
	}
	start := 0
	for start < n {
		end := start + size
		if end >= n {
			add(start, n)
			break
		}
		cut := findBreak(r, start+size/2, end)
		add(start, cut)
		start = cut - overlap
	}
	return out
}

// findBreak returns the best cut position in (lo, hi] (hi is exclusive end).
func findBreak(r []rune, lo, hi int) int {
	// paragraph: cut after the last "\n\n"
	for i := hi - 1; i > lo; i-- {
		if r[i] == '\n' && r[i-1] == '\n' {
			return i + 1
		}
	}
	// sentence end followed by space/newline
	for i := hi - 1; i > lo; i-- {
		if unicode.IsSpace(r[i]) && (r[i-1] == '.' || r[i-1] == '!' || r[i-1] == '?') {
			return i + 1
		}
	}
	for i := hi - 1; i > lo; i-- {
		if unicode.IsSpace(r[i]) {
			return i + 1
		}
	}
	return hi
}
