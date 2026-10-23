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

package hookjson

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// GetTopLevel returns the raw value of a top-level key. A missing file or key
// reports ok=false without error.
func GetTopLevel(path, key string) (json.RawMessage, bool, error) {
	data, err := os.ReadFile(resolve(path))
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, false, nil
	}
	top, err := parseObj(data)
	if err != nil {
		return nil, false, fmt.Errorf("parse %s: %w", path, err)
	}
	v, ok := top.m[key]
	return v, ok, nil
}

// SetTopLevel sets (or, with a nil value, deletes) one top-level key, keeping
// every other key and its order, the file mode, and writing atomically with a
// write-once .platynotch-backup. It reports whether the file changed. Invalid
// JSON is an error and leaves the file untouched.
func SetTopLevel(path, key string, value json.RawMessage) (bool, error) {
	if path == "" || key == "" {
		return false, errors.New("hookjson: path and key are required")
	}
	if value != nil && !json.Valid(value) {
		return false, errors.New("hookjson: value is not valid JSON")
	}
	path = resolve(path)
	data, err := os.ReadFile(path)
	exists := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	if value == nil && !exists {
		return false, nil
	}
	top := newObj()
	if len(bytes.TrimSpace(data)) > 0 {
		if top, err = parseObj(data); err != nil {
			return false, fmt.Errorf("parse %s: %w", path, err)
		}
	}
	old, had := top.m[key]
	if value == nil {
		if !had {
			return false, nil
		}
		top.del(key)
	} else {
		if had && compactEq(old, value) {
			return false, nil
		}
		top.set(key, value)
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

func compactEq(a, b json.RawMessage) bool {
	var x, y bytes.Buffer
	if json.Compact(&x, a) != nil || json.Compact(&y, b) != nil {
		return false
	}
	return bytes.Equal(x.Bytes(), y.Bytes())
}
