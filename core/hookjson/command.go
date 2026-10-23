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
// Modified for PlatyNotch: hook command construction and ownership detection
// replace AO's fixed "ao hooks <agent> " command prefix.

package hookjson

import "strings"

// Command builds the shell command an agent runs for one hook event:
// `"<bin>" hook <agent> <event>`. The binary path is always double-quoted so
// install locations with spaces (~/Library/Application Support/...) work.
func Command(bin, agent, event string) string {
	return `"` + quoteInner(bin) + `" hook ` + agent + " " + event
}

// quoteInner escapes the characters that stay special inside a POSIX
// double-quoted string.
func quoteInner(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '\\', '"', '$', '`':
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// IsOurs reports whether command was written by PlatyNotch: its first token (a
// double-quoted path or a bare path) has basename "notch" or "notch-pro" and is
// followed by " hook ". The data directory is deliberately not checked so
// relocated installs (PLATYNOTCH_HOME) are still recognised and cleaned up.
func IsOurs(command string) bool {
	command = strings.TrimLeft(command, " \t")
	var path, rest string
	if strings.HasPrefix(command, `"`) {
		var b strings.Builder
		i := 1
		closed := false
		for ; i < len(command); i++ {
			c := command[i]
			if c == '\\' && i+1 < len(command) {
				i++
				b.WriteByte(command[i])
				continue
			}
			if c == '"' {
				closed = true
				i++
				break
			}
			b.WriteByte(c)
		}
		if !closed {
			return false
		}
		path, rest = b.String(), command[i:]
	} else {
		sp := strings.IndexAny(command, " \t")
		if sp < 0 {
			return false
		}
		path, rest = command[:sp], command[sp:]
	}
	if !strings.HasPrefix(rest, " hook ") {
		return false
	}
	base := path
	if i := strings.LastIndexAny(base, `/\`); i >= 0 {
		base = base[i+1:]
	}
	base = strings.TrimSuffix(base, ".exe")
	return base == "notch" || base == "notch-pro"
}
