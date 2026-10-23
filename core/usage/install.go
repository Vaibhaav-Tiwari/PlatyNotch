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
	"encoding/json"
	"fmt"
	"path/filepath"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/hookjson"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
)

const statusLineKey = "statusLine"

func claudeSettings() string {
	return filepath.Join(paths.UserHome(), ".claude", "settings.json")
}

type statusLineObj struct {
	Type    string `json:"type"`
	Command string `json:"command"`
}

// InstallStatusline points Claude Code's statusLine at `notch statusline`,
// remembering the user's own statusLine: its command in
// config.Statusline.Previous and the whole value in PreviousRaw. If our
// wrapper is already installed, both are left alone.
func InstallStatusline(hookBin string) error {
	path := claudeSettings()
	raw, ok, err := hookjson.GetTopLevel(path, statusLineKey)
	if err != nil {
		return err
	}
	if ok {
		var cur statusLineObj
		if json.Unmarshal(raw, &cur) != nil || !hookjson.IsOursStatusline(cur.Command) {
			cfg, err := config.Load()
			if err != nil {
				return err
			}
			cfg.Statusline.Previous = cur.Command
			cfg.Statusline.PreviousRaw = append(json.RawMessage(nil), raw...)
			if err := config.Save(cfg); err != nil {
				return err
			}
		}
	}
	val, err := json.Marshal(statusLineObj{Type: "command", Command: hookjson.StatuslineCommand(hookBin)})
	if err != nil {
		return err
	}
	_, err = hookjson.SetTopLevel(path, statusLineKey, val)
	return err
}

// UninstallStatusline restores the user's previous statusLine verbatim (or
// removes ours when there was none). A statusLine that is not ours is left untouched.
func UninstallStatusline() error {
	path := claudeSettings()
	raw, ok, err := hookjson.GetTopLevel(path, statusLineKey)
	if err != nil {
		return err
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	if ok {
		var cur statusLineObj
		if json.Unmarshal(raw, &cur) == nil && hookjson.IsOursStatusline(cur.Command) {
			var val json.RawMessage
			switch {
			case len(cfg.Statusline.PreviousRaw) > 0 && json.Valid(cfg.Statusline.PreviousRaw):
				val = cfg.Statusline.PreviousRaw
			case cfg.Statusline.Previous != "": // config written before PreviousRaw existed
				if val, err = json.Marshal(statusLineObj{Type: "command", Command: cfg.Statusline.Previous}); err != nil {
					return err
				}
			}
			if _, err := hookjson.SetTopLevel(path, statusLineKey, val); err != nil {
				return err
			}
		}
	}
	if cfg.Statusline.Previous != "" || len(cfg.Statusline.PreviousRaw) > 0 {
		cfg.Statusline.Previous, cfg.Statusline.PreviousRaw = "", nil
		if err := config.Save(cfg); err != nil {
			return fmt.Errorf("clear previous statusline: %w", err)
		}
	}
	return nil
}
