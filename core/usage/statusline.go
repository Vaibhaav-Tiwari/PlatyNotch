// Copyright 2026 The PlatyNotch Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Package usage reads Claude Code's and Codex's rate-limit numbers and keeps
// them current for the notch.
package usage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/platynotch/platynotch/core/config"
	"github.com/platynotch/platynotch/core/paths"
	"github.com/platynotch/platynotch/core/protocol"
)

// now is the package clock; tests replace it.
var now = time.Now

const (
	previousTimeout = 2 * time.Second
	maxPreviousOut  = 64 << 10
)

// percentKeys are tried in order. Fractions (0-1) are only scaled for the keys
// that are ambiguous by nature; used_percentage/used_percent are already percent.
var percentKeys = []struct {
	key    string
	scaled bool
}{
	{"used_percentage", false},
	{"utilization", true},
	{"used_percent", false},
	{"percent", true},
}

// ParseStatusline extracts Claude's limits from the JSON Claude Code passes to
// a statusLine command. It looks for objects keyed five_hour / seven_day at any
// depth; other seven_day_* / five_hour_* objects land in Extra.
func ParseStatusline(input []byte) (*protocol.Limits, bool) {
	var root any
	if json.Unmarshal(input, &root) != nil {
		return nil, false
	}
	l := &protocol.Limits{UpdatedAt: now()}
	found := false
	walk(root, func(key string, v map[string]any) {
		w, ok := windowFrom(v)
		if !ok {
			return
		}
		switch {
		case key == "five_hour":
			if l.FiveHour == nil {
				l.FiveHour, found = &w, true
			}
		case key == "seven_day":
			if l.Weekly == nil {
				l.Weekly, found = &w, true
			}
		case strings.HasPrefix(key, "seven_day_") || strings.HasPrefix(key, "five_hour_"):
			if l.Extra == nil {
				l.Extra = map[string]protocol.Window{}
			}
			if _, dup := l.Extra[key]; !dup {
				l.Extra[key], found = w, true
			}
		}
	})
	if !found {
		return nil, false
	}
	return l, true
}

// walk calls fn for every object-valued key at any depth (maps iterate in
// random order, so callers must not depend on which duplicate wins).
func walk(v any, fn func(key string, obj map[string]any)) {
	switch t := v.(type) {
	case map[string]any:
		for k, c := range t {
			if m, ok := c.(map[string]any); ok {
				fn(k, m)
			}
			walk(c, fn)
		}
	case []any:
		for _, c := range t {
			walk(c, fn)
		}
	}
}

func windowFrom(m map[string]any) (protocol.Window, bool) {
	var w protocol.Window
	found := false
	for _, pk := range percentKeys {
		f, ok := m[pk.key].(float64)
		if !ok {
			continue
		}
		if pk.scaled && f >= 0 && f <= 1 {
			f *= 100
		}
		w.UsedPercent, found = math.Round(f*100)/100, true
		break
	}
	if !found {
		return w, false
	}
	w.ResetsAt = parseTime(m["resets_at"])
	return w, true
}

func parseTime(v any) *time.Time {
	switch t := v.(type) {
	case float64:
		if t <= 0 {
			return nil
		}
		if t > 1e11 { // milliseconds
			t /= 1000
		}
		tm := time.Unix(int64(t), 0)
		return &tm
	case string:
		if tm, err := time.Parse(time.RFC3339, t); err == nil {
			return &tm
		}
		if f, err := strconv.ParseFloat(t, 64); err == nil {
			return parseTime(f)
		}
	}
	return nil
}

// RunStatusline is `notch statusline`: save the limits, then print the user's
// own status line (or ours). It always prints something and returns 0.
func RunStatusline(stdin io.Reader, stdout io.Writer, cfg config.Config) int {
	in, _ := io.ReadAll(io.LimitReader(stdin, 4<<20))
	limits, ok := ParseStatusline(in)
	if ok {
		_ = writeUsage(paths.UsageFile(), limits)
	}
	if prev := strings.TrimSpace(cfg.Statusline.Previous); prev != "" {
		if out, ok := runPrevious(prev, in); ok {
			_, _ = io.WriteString(stdout, out)
			return 0
		}
	}
	_, _ = io.WriteString(stdout, defaultLine(in, limits)+"\n")
	return 0
}

// runPrevious runs the user's own statusLine command with our stdin, keeping
// at most maxPreviousOut bytes of its stdout. A command that exits but leaves
// a background child holding stdout (exec.ErrWaitDelay) still counts when it
// printed something.
func runPrevious(command string, stdin []byte) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), previousTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", command)
	cmd.Stdin = strings.NewReader(string(stdin))
	buf := &capWriter{max: maxPreviousOut}
	cmd.Stdout = buf // stderr stays nil: discarded
	cmd.WaitDelay = 200 * time.Millisecond
	if err := cmd.Run(); err != nil && !errors.Is(err, exec.ErrWaitDelay) {
		return "", false
	}
	out := buf.String()
	if strings.TrimSpace(out) == "" {
		return "", false
	}
	return out, true
}

// capWriter keeps the first max bytes and silently discards the rest, so a
// flooding command never blocks on a full pipe or grows memory.
type capWriter struct {
	mu  sync.Mutex
	b   []byte
	max int
}

func (w *capWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if room := w.max - len(w.b); room > 0 {
		w.b = append(w.b, p[:min(room, len(p))]...)
	}
	return len(p), nil
}

func (w *capWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return string(w.b)
}

func defaultLine(in []byte, l *protocol.Limits) string {
	var s struct {
		Model struct {
			DisplayName string `json:"display_name"`
			ID          string `json:"id"`
		} `json:"model"`
	}
	_ = json.Unmarshal(in, &s)
	name := s.Model.DisplayName
	if name == "" {
		name = s.Model.ID
	}
	if name == "" {
		name = "Claude"
	}
	if l != nil && l.FiveHour != nil {
		return fmt.Sprintf("%s · 5h %s%%", name, strconv.FormatFloat(l.FiveHour.UsedPercent, 'f', -1, 64))
	}
	return name
}

// writeUsage replaces usage.json atomically.
func writeUsage(path string, l *protocol.Limits) error {
	b, err := json.Marshal(l)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".usage-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }()
	if _, err := tmp.Write(b); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
