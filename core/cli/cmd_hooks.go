package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents"
)

// agentStatus is one row of `hooks status --json` (read by the Mac app).
type agentStatus struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Detected   bool   `json:"detected"`
	Installed  bool   `json:"installed"`
	ConfigPath string `json:"config_path"`
	Approvals  string `json:"approvals"` // none | experimental | verified
	Error      string `json:"error,omitempty"`
}

func approvalsName(s agents.ApprovalSupport) string {
	switch s {
	case agents.ApprovalsVerified:
		return "verified"
	case agents.ApprovalsExperimental:
		return "experimental"
	}
	return "none"
}

func statusOf(a agents.Adapter) agentStatus {
	st := agentStatus{
		ID: a.ID(), Name: a.Name(), Detected: a.Detect(),
		ConfigPath: a.ConfigPath(), Approvals: approvalsName(a.Approvals()),
	}
	ok, err := a.HooksInstalled()
	st.Installed = ok
	if err != nil {
		st.Error = err.Error()
	}
	return st
}

// hooks: install|uninstall|status [agent|all] [--json]. With "all" (the
// default), install covers detected agents only; uninstall and status cover
// every adapter.
func (a *app) hooks(_ context.Context, args []string) int {
	var pos []string
	asJSON := false
	for _, arg := range args {
		switch {
		case arg == "--json":
			asJSON = true
		case strings.HasPrefix(arg, "-"):
			return a.usageErr("hooks", "unknown flag "+arg)
		default:
			pos = append(pos, arg)
		}
	}
	if len(pos) == 0 || len(pos) > 2 {
		return a.usageErr("hooks", "expected a subcommand and at most one agent")
	}
	sub, target := pos[0], "all"
	if len(pos) == 2 {
		target = pos[1]
	}
	switch sub {
	case "install", "uninstall", "status":
	default:
		return a.usageErr("hooks", "unknown subcommand "+sub)
	}
	if asJSON && sub != "status" {
		return a.usageErr("hooks", "--json is only for status")
	}

	var list []agents.Adapter
	if target == "all" {
		list = agents.All()
	} else {
		ad, ok := agents.Get(target)
		if !ok {
			ids := []string{}
			for _, x := range agents.All() {
				ids = append(ids, x.ID())
			}
			return a.usageErr("hooks", fmt.Sprintf("unknown agent %q (one of: %s, all)", target, strings.Join(ids, ", ")))
		}
		list = []agents.Adapter{ad}
	}

	switch sub {
	case "status":
		rows := make([]agentStatus, 0, len(list))
		for _, ad := range list {
			rows = append(rows, statusOf(ad))
		}
		if asJSON {
			b, _ := json.MarshalIndent(rows, "", "  ")
			fmt.Fprintln(a.stdout, string(b))
			return 0
		}
		for _, r := range rows {
			state := "not installed"
			if r.Installed {
				state = "installed"
			}
			if r.Error != "" {
				state = "error: " + r.Error
			}
			det := "detected"
			if !r.Detected {
				det = "not detected"
			}
			fmt.Fprintf(a.stdout, "%-12s %-13s hooks %s (approvals: %s)\n", r.ID, det, state, r.Approvals)
		}
		return 0

	case "install":
		bin, err := ensureHookBinary()
		if err != nil {
			return a.fail("hooks", err)
		}
		failed := false
		for _, ad := range list {
			if target == "all" && !ad.Detect() {
				continue
			}
			if _, err := ad.InstallHooks(bin); err != nil {
				fmt.Fprintf(a.stderr, "notch hooks: %s: %v\n", ad.ID(), err)
				failed = true
				continue
			}
			fmt.Fprintf(a.stdout, "%s: hooks installed in %s\n", ad.ID(), ad.ConfigPath())
		}
		if failed {
			return 1
		}
		return 0

	default: // uninstall
		failed := false
		for _, ad := range list {
			changed, err := ad.UninstallHooks()
			if err != nil {
				fmt.Fprintf(a.stderr, "notch hooks: %s: %v\n", ad.ID(), err)
				failed = true
				continue
			}
			if changed || target != "all" {
				fmt.Fprintf(a.stdout, "%s: hooks uninstalled\n", ad.ID())
			}
		}
		if failed {
			return 1
		}
		return 0
	}
}
