package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/hookjson"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
)

// doctor reports the health of an install. Only an unreachable core, an
// invalid config or an unreadable agent config count as failures (exit 1);
// everything else is informational.
func (a *app) doctor(_ context.Context, args []string) int {
	if len(args) != 0 {
		return a.usageErr("doctor", "takes no arguments")
	}
	failed := false
	line := func(ok bool, format string, v ...any) {
		mark := "ok  "
		if !ok {
			mark, failed = "FAIL", true
		}
		fmt.Fprintf(a.stdout, "%s  %s\n", mark, fmt.Sprintf(format, v...))
	}
	info := func(format string, v ...any) {
		fmt.Fprintf(a.stdout, "--    %s\n", fmt.Sprintf(format, v...))
	}

	fmt.Fprintf(a.stdout, "notch %s (%s)\n", Version, a.edition)

	if c, err := dialCore(); err != nil {
		line(false, "%v", err)
	} else {
		c.Close()
		line(true, "core reachable on %s", paths.Socket())
	}

	if _, err := config.Load(); err != nil {
		line(false, "config %s is invalid: %v", paths.Config(), err)
	} else {
		line(true, "config %s", paths.Config())
	}

	if _, err := os.Stat(paths.HookBinary()); err != nil {
		info("hook binary %s missing (created by `notch hooks install`)", paths.HookBinary())
	} else {
		line(true, "hook binary %s", paths.HookBinary())
	}

	for _, ad := range agents.All() {
		st := statusOf(ad)
		switch {
		case st.Error != "":
			line(false, "%s: cannot read %s: %s", st.Name, st.ConfigPath, st.Error)
		case !st.Detected:
			info("%s: not detected", st.Name)
		case st.Installed:
			line(true, "%s: hooks installed (approvals: %s)", st.Name, st.Approvals)
		default:
			info("%s: detected, hooks not installed (run `notch hooks install %s`)", st.Name, st.ID)
		}
		if st.ID == "codex" {
			info("Codex: user-level hooks may need hook trust in Codex before they run; if no events arrive, trust them in Codex")
		}
	}

	installed, err := statuslineInstalled()
	switch {
	case err != nil:
		info("Claude Code statusline: cannot read settings: %v", err)
	case installed:
		line(true, "Claude Code statusline installed (usage limits)")
	default:
		info("Claude Code statusline not installed (run `notch statusline install` for usage limits)")
	}

	if failed {
		return 1
	}
	return 0
}

func statuslineInstalled() (bool, error) {
	path := filepath.Join(paths.UserHome(), ".claude", "settings.json")
	raw, ok, err := hookjson.GetTopLevel(path, "statusLine")
	if err != nil || !ok {
		return false, err
	}
	var sl struct {
		Command string `json:"command"`
	}
	if json.Unmarshal(raw, &sl) != nil {
		return false, nil
	}
	return hookjson.IsOursStatusline(sl.Command), nil
}
