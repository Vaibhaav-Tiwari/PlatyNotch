// Package discover backfills sessions that started before the core by reading
// Claude Code and Codex transcript files.
package discover

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/platynotch/platynotch/core/protocol"
	"github.com/platynotch/platynotch/core/session"
)

const (
	headBytes    = 64 << 10
	tailBytes    = 256 << 10
	maxTitleRune = 80
)

// Claude returns idle sessions found under projectsDir/*/*.jsonl that were
// modified after since. When the same session id appears in several project
// directories the most recently modified file wins.
func Claude(projectsDir string, since time.Time) []protocol.Session {
	files, _ := filepath.Glob(filepath.Join(projectsDir, "*", "*.jsonl"))
	newest := map[string]fileInfo{}
	var order []string
	for _, f := range files {
		fi, err := os.Stat(f)
		if err != nil || !fi.Mode().IsRegular() || !fi.ModTime().After(since) {
			continue
		}
		id := strings.TrimSuffix(filepath.Base(f), ".jsonl")
		cur, ok := newest[id]
		if !ok {
			order = append(order, id)
		}
		if !ok || fi.ModTime().After(cur.mod) {
			newest[id] = fileInfo{path: f, mod: fi.ModTime()}
		}
	}
	var out []protocol.Session
	for _, id := range order {
		fi := newest[id]
		var cwd, title string
		var started time.Time
		for _, line := range readLines(fi.path) {
			var l claudeLine
			if json.Unmarshal(line, &l) != nil {
				continue
			}
			if cwd == "" && l.CWD != "" {
				cwd = l.CWD
			}
			if started.IsZero() {
				started = parseTime(l.Timestamp)
			}
			if l.Type == "user" && !l.IsMeta {
				if t := claudePrompt(l.Message.Content); t != "" {
					title = t
				}
			}
		}
		out = append(out, build("claude-code", "Claude Code", id, cwd, title, started, fi.mod))
	}
	return out
}

// Codex returns idle sessions found under sessionsDir/YYYY/MM/DD/rollout-*.jsonl
// that were modified after since.
func Codex(sessionsDir string, since time.Time) []protocol.Session {
	files, _ := filepath.Glob(filepath.Join(sessionsDir, "*", "*", "*", "rollout-*.jsonl"))
	var out []protocol.Session
	seen := map[string]int{}
	for _, f := range files {
		fi, err := os.Stat(f)
		if err != nil || !fi.Mode().IsRegular() || !fi.ModTime().After(since) {
			continue
		}
		var id, cwd, title string
		var started time.Time
		for _, line := range readLines(f) {
			var l codexLine
			if json.Unmarshal(line, &l) != nil {
				continue
			}
			switch l.Type {
			case "session_meta":
				if id == "" {
					id, cwd = l.Payload.ID, l.Payload.CWD
					started = parseTime(l.Payload.Timestamp)
					if started.IsZero() {
						started = parseTime(l.Timestamp)
					}
				}
			case "event_msg":
				switch l.Payload.Type {
				case "user_message":
					if t := firstLine(l.Payload.Message); t != "" {
						title = t
					}
				case "item_completed":
					if l.Payload.Item.Type == "UserMessage" {
						if t := textBlocks(l.Payload.Item.Content); t != "" {
							title = t
						}
					}
				}
			case "response_item":
				if l.Payload.Type == "message" && l.Payload.Role == "user" {
					if t := textBlocks(l.Payload.Content); t != "" && !strings.HasPrefix(t, "<") {
						title = t
					}
				}
			}
		}
		if id == "" {
			continue
		}
		s := build("codex", "Codex", id, cwd, title, started, fi.ModTime())
		if i, ok := seen[id]; ok {
			if s.UpdatedAt.After(out[i].UpdatedAt) {
				out[i] = s
			}
			continue
		}
		seen[id] = len(out)
		out = append(out, s)
	}
	return out
}

type fileInfo struct {
	path string
	mod  time.Time
}

type claudeLine struct {
	Type      string `json:"type"`
	CWD       string `json:"cwd"`
	Timestamp string `json:"timestamp"`
	IsMeta    bool   `json:"isMeta"`
	Message   struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type codexLine struct {
	Type      string `json:"type"`
	Timestamp string `json:"timestamp"`
	Payload   struct {
		Type      string          `json:"type"`
		ID        string          `json:"id"`
		CWD       string          `json:"cwd"`
		Timestamp string          `json:"timestamp"`
		Message   string          `json:"message"`
		Role      string          `json:"role"`
		Content   json.RawMessage `json:"content"`
		Item      struct {
			Type    string          `json:"type"`
			Content json.RawMessage `json:"content"`
		} `json:"item"`
	} `json:"payload"`
}

func build(agent, name, id, cwd, title string, started, mod time.Time) protocol.Session {
	if started.IsZero() {
		started = mod
	}
	s := protocol.Session{
		Key: session.Key(agent, id, 0), Agent: agent, AgentName: name, SessionID: id,
		CWD: cwd, State: protocol.StateIdle, Title: title, StartedAt: started, UpdatedAt: mod,
	}
	if cwd != "" {
		s.Project = filepath.Base(cwd)
	}
	return s
}

// claudePrompt extracts prompt text from message.content (string or blocks),
// ignoring tool results and command/system wrappers.
func claudePrompt(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if isWrapper(s) {
			return ""
		}
		return firstLine(s)
	}
	t := textBlocks(raw)
	if isWrapper(t) {
		return ""
	}
	return t
}

func isWrapper(s string) bool {
	s = strings.TrimSpace(s)
	for _, p := range []string{"<command-name>", "<command-message>", "<local-command", "<system-reminder>"} {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// textBlocks returns the first line of the first non-empty text block.
func textBlocks(raw json.RawMessage) string {
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) != nil {
		return ""
	}
	for _, b := range blocks {
		if b.Type == "tool_result" {
			continue
		}
		if t := firstLine(b.Text); t != "" {
			return t
		}
	}
	return ""
}

// firstLine mirrors session's title truncation: first line, 80 runes.
func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = strings.TrimSpace(s[:i])
	}
	if r := []rune(s); len(r) > maxTitleRune {
		s = string(r[:maxTitleRune])
	}
	return s
}

func parseTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// readLines returns complete lines from the first 64 KB and last 256 KB of the
// file, in order, without duplicates. Partial lines at window edges are dropped.
func readLines(path string) [][]byte {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil
	}
	size := fi.Size()
	if size <= headBytes+tailBytes {
		buf, err := io.ReadAll(f)
		if err != nil {
			return nil
		}
		return bytes.Split(buf, []byte("\n"))
	}
	head := make([]byte, headBytes)
	n, _ := f.ReadAt(head, 0)
	head = head[:n]
	if i := bytes.LastIndexByte(head, '\n'); i >= 0 {
		head = head[:i]
	} else {
		head = nil
	}
	tail := make([]byte, tailBytes)
	n, _ = f.ReadAt(tail, size-tailBytes)
	tail = tail[:n]
	if i := bytes.IndexByte(tail, '\n'); i >= 0 {
		tail = tail[i+1:]
	} else {
		tail = nil
	}
	return append(bytes.Split(head, []byte("\n")), bytes.Split(tail, []byte("\n"))...)
}
