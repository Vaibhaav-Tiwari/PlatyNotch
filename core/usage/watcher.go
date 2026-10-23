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
	"context"
	"encoding/json"
	"os"
	"time"

	"github.com/platynotch/platynotch/core/protocol"
)

// Watcher polls usage.json (written by `notch statusline`) and the newest
// Codex rollout, calling onChange when the values change.
type Watcher struct {
	// Interval between polls (default 5 s).
	Interval time.Duration

	usageFile string
	codexDir  string
	onChange  func(protocol.Usage)
	last      protocol.Usage
	sent      bool
}

func NewWatcher(usageFile, codexSessionsDir string, onChange func(protocol.Usage)) *Watcher {
	return &Watcher{Interval: 5 * time.Second, usageFile: usageFile, codexDir: codexSessionsDir, onChange: onChange}
}

// Run polls until ctx is done. It polls once immediately.
func (w *Watcher) Run(ctx context.Context) {
	w.poll()
	iv := w.Interval
	if iv <= 0 {
		iv = 5 * time.Second
	}
	t := time.NewTicker(iv)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.poll()
		}
	}
}

func (w *Watcher) poll() {
	var u protocol.Usage
	if b, err := os.ReadFile(w.usageFile); err == nil {
		var l protocol.Limits
		if json.Unmarshal(b, &l) == nil && (l.FiveHour != nil || l.Weekly != nil || len(l.Extra) > 0) {
			u.Claude = &l
		}
	}
	if p, mt, ok := newestRollout(w.codexDir); ok {
		if lines, err := readTail(p, tailBytes); err == nil {
			// Base relative resets on the file's mtime so repeated polls of an
			// unchanged file yield identical values.
			u.Codex, _ = parseCodex(lines, mt)
		}
	}
	if !w.sent && u.Claude == nil && u.Codex == nil {
		return
	}
	if w.sent && usageEqual(w.last, u) {
		return
	}
	w.last, w.sent = u, true
	if w.onChange != nil {
		w.onChange(u)
	}
}

func usageEqual(a, b protocol.Usage) bool {
	return limitsEqual(a.Claude, b.Claude) && limitsEqual(a.Codex, b.Codex)
}

func limitsEqual(a, b *protocol.Limits) bool {
	if a == nil || b == nil {
		return a == b
	}
	if !a.UpdatedAt.Equal(b.UpdatedAt) || !winEqual(a.FiveHour, b.FiveHour) || !winEqual(a.Weekly, b.Weekly) || len(a.Extra) != len(b.Extra) {
		return false
	}
	for k, av := range a.Extra {
		bv, ok := b.Extra[k]
		if !ok || !winEqual(&av, &bv) {
			return false
		}
	}
	return true
}

func winEqual(a, b *protocol.Window) bool {
	if a == nil || b == nil {
		return a == b
	}
	if a.UsedPercent != b.UsedPercent {
		return false
	}
	if a.ResetsAt == nil || b.ResetsAt == nil {
		return a.ResetsAt == b.ResetsAt
	}
	return a.ResetsAt.Equal(*b.ResetsAt)
}
