// Copyright 2026 Untrivial
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
//
// Ported from agent-orchestrator (https://github.com/aoagents/agent-orchestrator,
// Apache-2.0, commit 60202ba): backend/internal/adapters/agent/hooksjson and
// hookutil.
//
// Modified for PlatyNotch: merged hooksjson and hookutil into one package;
// replaced the Manager/workspace model with a path-based Spec for user-level
// config files; ownership is decided by IsOurs instead of a command prefix;
// added the Claude/Cursor/Codex formats, per-entry timeouts, a write-once
// backup, mode preservation, and order-preserving (byte-faithful) passthrough
// of everything PlatyNotch does not own.

// Package hookjson installs and removes PlatyNotch's hook entries in coding
// agents' JSON config files without disturbing anything else in them.
package hookjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Format selects the on-disk shape of the hooks file.
type Format int

const (
	// FormatClaude: hooks.<Event>[] = {matcher?, hooks:[{type:"command", command, timeout?}]}.
	FormatClaude Format = iota
	// FormatCursor: {version:1, hooks.<event>[] = {command, timeout?}} (flat entries).
	FormatCursor
	// FormatCodex: Codex's hooks.json uses the same matcher-group shape as Claude.
	FormatCodex
)

func (f Format) flat() bool { return f == FormatCursor }

// Entry is one hook to install.
type Entry struct {
	Event   string
	Matcher *string
	Command string
	// TimeoutSec is written verbatim to the agent's `timeout` field, in the
	// agent's own unit: seconds for Claude/Codex/Cursor, milliseconds for
	// Gemini/Qwen. 0 omits the field.
	TimeoutSec int
}

// Spec describes one config file and the entries PlatyNotch owns in it.
type Spec struct {
	Path    string
	Format  Format
	Entries []Entry
}

const (
	backupSuffix  = ".platynotch-backup"
	schemaVersion = "1"
)

// Install merges Spec.Entries into the file, creating it (0600) if absent.
// Every existing PlatyNotch entry (by IsOurs) in an affected event is replaced,
// so a moved binary never leaves stale or duplicate hooks. Only the events it
// writes are parsed: other events pass through verbatim, however malformed,
// while one of its own events holding a non-array value is an error. It
// reports whether the file changed. Invalid JSON is an error and leaves the
// file untouched.
func Install(s Spec) (bool, error) { return apply(s, false) }

// Uninstall removes every PlatyNotch entry from the file, leaving user hooks
// and unrelated settings untouched. A missing file is a no-op. Events whose
// value is not an array (and array items that are not objects) cannot hold
// PlatyNotch entries and are passed through as they are.
func Uninstall(s Spec) (bool, error) { return apply(s, true) }

// Installed reports whether each event in Spec.Entries has a PlatyNotch entry
// (or, with no entries, whether any event does). A missing file means no;
// events whose value is not an array are skipped.
func Installed(s Spec) (bool, error) {
	data, err := os.ReadFile(resolve(s.Path))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	_, hooks, err := parseFile(data, s.Path)
	if err != nil {
		return false, err
	}
	has := map[string]bool{}
	for _, ev := range hooks.keys {
		items, err := parseArray(hooks.m[ev], ev)
		if err != nil {
			continue // a malformed user-owned event holds nothing of ours
		}
		has[ev] = len(oursIn(items, s.Format.flat())) > 0
	}
	if len(s.Entries) == 0 {
		for _, v := range has {
			if v {
				return true, nil
			}
		}
		return false, nil
	}
	for _, e := range s.Entries {
		if !has[e.Event] {
			return false, nil
		}
	}
	return true, nil
}

func apply(s Spec, uninstall bool) (bool, error) {
	if strings.TrimSpace(s.Path) == "" {
		return false, errors.New("hookjson: Path is required")
	}
	path := resolve(s.Path)
	data, err := os.ReadFile(path)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	if uninstall && !exists {
		return false, nil
	}
	top, hooks, err := parseFile(data, s.Path)
	if err != nil {
		return false, err
	}
	flat := s.Format.flat()
	changed := false

	if uninstall {
		for _, ev := range append([]string(nil), hooks.keys...) {
			items, err := parseArray(hooks.m[ev], ev)
			if err != nil {
				continue // not an array: nothing of ours; pass it through
			}
			kept, removed, err := stripOurs(items, flat)
			if err != nil {
				return false, err
			}
			if !removed {
				continue
			}
			changed = true
			if len(kept) == 0 {
				hooks.del(ev)
			} else {
				hooks.set(ev, marshalArray(kept))
			}
		}
	} else {
		byEvent := map[string][]Entry{}
		var order []string
		for _, e := range s.Entries {
			if e.Command == "" || e.Event == "" {
				continue
			}
			if _, ok := byEvent[e.Event]; !ok {
				order = append(order, e.Event)
			}
			byEvent[e.Event] = append(byEvent[e.Event], e)
		}
		for _, ev := range order {
			want := byEvent[ev]
			var items []json.RawMessage
			if raw, ok := hooks.m[ev]; ok {
				if items, err = parseArray(raw, ev); err != nil {
					return false, err
				}
			}
			if satisfied(items, want, flat) {
				continue
			}
			kept, _, err := stripOurs(items, flat)
			if err != nil {
				return false, err
			}
			for _, e := range want {
				kept = append(kept, newItem(e, flat))
			}
			hooks.set(ev, marshalArray(kept))
			changed = true
		}
		if changed && flat {
			if _, ok := top.m["version"]; !ok {
				top.set("version", json.RawMessage(schemaVersion))
			}
		}
	}
	if !changed {
		return false, nil
	}

	if len(hooks.keys) == 0 {
		top.del("hooks")
	} else {
		top.set("hooks", hooks.marshal())
	}
	var out bytes.Buffer
	if err := json.Indent(&out, top.marshal(), "", "  "); err != nil {
		return false, err
	}
	out.WriteByte('\n')

	perm := os.FileMode(0o600)
	if exists {
		if st, err := os.Stat(path); err == nil {
			perm = st.Mode().Perm()
		}
		if len(bytes.TrimSpace(data)) > 0 {
			if err := writeBackupOnce(path+backupSuffix, data); err != nil {
				return false, err
			}
		}
	} else if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return false, fmt.Errorf("create %s: %w", filepath.Dir(path), err)
	}
	if err := atomicWrite(path, out.Bytes(), perm); err != nil {
		return false, fmt.Errorf("write %s: %w", path, err)
	}
	return true, nil
}

// resolve follows a symlinked config so the rename replaces the target, not the link.
func resolve(path string) string {
	if p, err := filepath.EvalSymlinks(path); err == nil {
		return p
	}
	return path
}

func writeBackupOnce(path string, data []byte) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := atomicWrite(path, data, 0o600); err != nil {
		return fmt.Errorf("write backup: %w", err)
	}
	return nil
}

// atomicWrite writes data via a temp file in the same directory followed by a
// rename, so a crash can never leave a truncated config the agent fails to parse.
func atomicWrite(path string, data []byte, perm os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".platynotch-tmp-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer func() { _ = os.Remove(name) }() // no-op once renamed
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(perm); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

// ---- ordered JSON object (preserves key order and raw values) ----

type obj struct {
	keys []string
	m    map[string]json.RawMessage
}

func newObj() *obj { return &obj{m: map[string]json.RawMessage{}} }

func parseObj(data []byte) (*obj, error) {
	if !json.Valid(data) {
		return nil, errors.New("invalid JSON")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	if d, ok := tok.(json.Delim); !ok || d != '{' {
		return nil, errors.New("expected a JSON object")
	}
	o := newObj()
	for dec.More() {
		kt, err := dec.Token()
		if err != nil {
			return nil, err
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, err
		}
		o.set(kt.(string), raw)
	}
	return o, nil
}

func (o *obj) set(k string, v json.RawMessage) {
	if _, ok := o.m[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.m[k] = v
}

func (o *obj) del(k string) {
	if _, ok := o.m[k]; !ok {
		return
	}
	delete(o.m, k)
	for i, kk := range o.keys {
		if kk == k {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			break
		}
	}
}

func (o *obj) marshal() json.RawMessage {
	var b bytes.Buffer
	b.WriteByte('{')
	for i, k := range o.keys {
		if i > 0 {
			b.WriteByte(',')
		}
		kb, _ := json.Marshal(k)
		b.Write(kb)
		b.WriteByte(':')
		b.Write(o.m[k])
	}
	b.WriteByte('}')
	return b.Bytes()
}

func marshalArray(items []json.RawMessage) json.RawMessage {
	return append(append([]byte{'['}, bytes.Join(rawBytes(items), []byte{','})...), ']')
}

func rawBytes(items []json.RawMessage) [][]byte {
	out := make([][]byte, len(items))
	for i, it := range items {
		out[i] = it
	}
	return out
}

func parseFile(data []byte, path string) (top, hooks *obj, err error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return newObj(), newObj(), nil
	}
	if top, err = parseObj(data); err != nil {
		return nil, nil, fmt.Errorf("parse %s: %w", path, err)
	}
	hooks = newObj()
	if raw, ok := top.m["hooks"]; ok && string(bytes.TrimSpace(raw)) != "null" {
		if hooks, err = parseObj(raw); err != nil {
			return nil, nil, fmt.Errorf("parse hooks in %s: %w", path, err)
		}
	}
	return top, hooks, nil
}

func parseArray(raw json.RawMessage, event string) ([]json.RawMessage, error) {
	var items []json.RawMessage
	if err := json.Unmarshal(raw, &items); err != nil {
		return nil, fmt.Errorf("parse %s hooks: %w", event, err)
	}
	return items, nil
}

// ---- hook entry logic ----

type ref struct {
	matcher *string
	command string
	timeout int
}

// commandOf extracts command from a hook entry; non-objects have none.
func commandOf(raw json.RawMessage) (cmd string, ok bool) {
	var e struct {
		Command string `json:"command"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return "", false
	}
	return e.Command, true
}

func timeoutOf(raw json.RawMessage) int {
	var e struct {
		Timeout int `json:"timeout"`
	}
	_ = json.Unmarshal(raw, &e)
	return e.Timeout
}

func matcherOf(raw json.RawMessage) *string {
	var e struct {
		Matcher *string `json:"matcher"`
	}
	_ = json.Unmarshal(raw, &e)
	return e.Matcher
}

// oursIn lists PlatyNotch entries in an event array. For matcher-group formats
// the matcher comes from the enclosing group.
func oursIn(items []json.RawMessage, flat bool) []ref {
	var out []ref
	for _, it := range items {
		if flat {
			if c, ok := commandOf(it); ok && IsOurs(c) {
				out = append(out, ref{matcherOf(it), c, timeoutOf(it)})
			}
			continue
		}
		var g struct {
			Hooks []json.RawMessage `json:"hooks"`
		}
		if json.Unmarshal(it, &g) != nil {
			continue
		}
		for _, h := range g.Hooks {
			if c, ok := commandOf(h); ok && IsOurs(c) {
				out = append(out, ref{matcherOf(it), c, timeoutOf(h)})
			}
		}
	}
	return out
}

func sameMatcher(a, b *string) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return *a == *b
}

// satisfied reports whether the array already holds exactly the wanted
// PlatyNotch entries and nothing else of ours.
func satisfied(items []json.RawMessage, want []Entry, flat bool) bool {
	have := oursIn(items, flat)
	if len(have) != len(want) {
		return false
	}
	used := make([]bool, len(have))
	for _, w := range want {
		found := false
		for i, h := range have {
			if !used[i] && h.command == w.Command && h.timeout == w.TimeoutSec && sameMatcher(h.matcher, w.Matcher) {
				used[i], found = true, true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// stripOurs removes PlatyNotch entries. Groups emptied by the removal are
// dropped; groups that were already empty, and non-object items, are kept.
func stripOurs(items []json.RawMessage, flat bool) ([]json.RawMessage, bool, error) {
	out := make([]json.RawMessage, 0, len(items))
	removed := false
	for _, it := range items {
		if flat {
			if c, ok := commandOf(it); ok && IsOurs(c) {
				removed = true
				continue
			}
			out = append(out, it)
			continue
		}
		g, err := parseObj(it)
		if err != nil {
			out = append(out, it)
			continue
		}
		hraw, ok := g.m["hooks"]
		if !ok {
			out = append(out, it)
			continue
		}
		var hs []json.RawMessage
		if json.Unmarshal(hraw, &hs) != nil {
			out = append(out, it)
			continue
		}
		kept := make([]json.RawMessage, 0, len(hs))
		for _, h := range hs {
			if c, ok := commandOf(h); ok && IsOurs(c) {
				continue
			}
			kept = append(kept, h)
		}
		if len(kept) == len(hs) {
			out = append(out, it)
			continue
		}
		removed = true
		if len(kept) == 0 {
			continue
		}
		g.set("hooks", marshalArray(kept))
		out = append(out, g.marshal())
	}
	return out, removed, nil
}

func newItem(e Entry, flat bool) json.RawMessage {
	hook := newObj()
	if !flat {
		hook.set("type", json.RawMessage(`"command"`))
	}
	cb, _ := json.Marshal(e.Command)
	hook.set("command", cb)
	if e.TimeoutSec > 0 {
		hook.set("timeout", json.RawMessage(fmt.Sprint(e.TimeoutSec)))
	}
	if flat {
		if e.Matcher != nil {
			mb, _ := json.Marshal(*e.Matcher)
			hook.set("matcher", mb)
		}
		return hook.marshal()
	}
	g := newObj()
	if e.Matcher != nil {
		mb, _ := json.Marshal(*e.Matcher)
		g.set("matcher", mb)
	}
	g.set("hooks", marshalArray([]json.RawMessage{hook.marshal()}))
	return g.marshal()
}
