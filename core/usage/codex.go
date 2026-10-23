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

package usage

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/platynotch/platynotch/core/protocol"
)

// tailBytes is how much of the newest rollout file is read.
const tailBytes = 256 * 1024

// ParseCodexRollout takes rollout JSONL lines and returns the limits from the
// last line carrying `rate_limits` at any nesting depth.
func ParseCodexRollout(lines [][]byte) (*protocol.Limits, bool) {
	return parseCodex(lines, now())
}

// parseCodex resolves relative resets (resets_in_seconds) against base.
func parseCodex(lines [][]byte, base time.Time) (*protocol.Limits, bool) {
	for i := len(lines) - 1; i >= 0; i-- {
		ln := bytes.TrimSpace(lines[i])
		if len(ln) == 0 || !bytes.Contains(ln, []byte("rate_limits")) {
			continue
		}
		var root any
		if json.Unmarshal(ln, &root) != nil {
			continue
		}
		rl := findKey(root, "rate_limits")
		if rl == nil {
			continue
		}
		l := &protocol.Limits{UpdatedAt: base}
		if w, ok := codexWindow(rl["primary"], base); ok {
			l.FiveHour = &w
		}
		if w, ok := codexWindow(rl["secondary"], base); ok {
			l.Weekly = &w
		}
		if l.FiveHour != nil || l.Weekly != nil {
			return l, true
		}
	}
	return nil, false
}

func findKey(v any, key string) map[string]any {
	switch t := v.(type) {
	case map[string]any:
		if m, ok := t[key].(map[string]any); ok {
			return m
		}
		for _, c := range t {
			if m := findKey(c, key); m != nil {
				return m
			}
		}
	case []any:
		for _, c := range t {
			if m := findKey(c, key); m != nil {
				return m
			}
		}
	}
	return nil
}

func codexWindow(v any, base time.Time) (protocol.Window, bool) {
	m, ok := v.(map[string]any)
	if !ok {
		return protocol.Window{}, false
	}
	p, ok := m["used_percent"].(float64)
	if !ok {
		return protocol.Window{}, false
	}
	w := protocol.Window{UsedPercent: p}
	if t := parseTime(m["resets_at"]); t != nil {
		w.ResetsAt = t
	} else if s, ok := m["resets_in_seconds"].(float64); ok && s >= 0 {
		t := base.Add(time.Duration(s * float64(time.Second)))
		w.ResetsAt = &t
	}
	return w, true
}

// newestRollout returns the rollout-*.jsonl with the latest mtime under
// dir/YYYY/MM/DD/.
func newestRollout(dir string) (path string, mtime time.Time, ok bool) {
	files, _ := filepath.Glob(filepath.Join(dir, "*", "*", "*", "rollout-*.jsonl"))
	sort.Strings(files)
	for _, f := range files {
		st, err := os.Stat(f)
		if err != nil || st.IsDir() {
			continue
		}
		if !ok || st.ModTime().After(mtime) {
			path, mtime, ok = f, st.ModTime(), true
		}
	}
	return
}

// readTail returns the lines in the last max bytes of the file, dropping a
// leading partial line when the read starts mid-file.
func readTail(path string, max int64) ([][]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	off := int64(0)
	if st.Size() > max {
		off = st.Size() - max
	}
	buf := make([]byte, st.Size()-off)
	if _, err := f.ReadAt(buf, off); err != nil && err != io.EOF {
		return nil, err
	}
	lines := bytes.Split(buf, []byte("\n"))
	if off > 0 && len(lines) > 0 {
		lines = lines[1:]
	}
	return lines, nil
}
