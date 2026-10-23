package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/wire"
)

const (
	cliDialTimeout = time.Second
	cliReplyBudget = 5 * time.Second
	cliClient      = "notch-cli"
)

// coreConn is a short-lived CLI connection. It says hello with role "cli",
// which never counts as a decider: a `notch status` or `notch approve` must
// not make hooks wait for an answer nobody will give.
type coreConn struct {
	nc net.Conn
	r  *wire.Reader
	w  *wire.Writer
}

func dialCore() (*coreConn, error) {
	sock := paths.Socket()
	nc, err := net.DialTimeout("unix", sock, cliDialTimeout)
	if err != nil {
		return nil, fmt.Errorf("core is not running (no answer on %s)", sock)
	}
	_ = nc.SetDeadline(time.Now().Add(cliReplyBudget))
	c := &coreConn{nc: nc, r: wire.NewReader(nc), w: wire.NewWriter(nc)}
	if err := c.w.Send(protocol.TypeHello, "", protocol.Hello{Role: protocol.RoleCLI, Client: cliClient + "/" + Version, Version: protocol.Version}); err != nil {
		nc.Close()
		return nil, fmt.Errorf("core is not running: %w", err)
	}
	return c, nil
}

func (c *coreConn) Close() error { return c.nc.Close() }

// reply reads until a message carrying id arrives. An error reply becomes a Go
// error.
func (c *coreConn) reply(id string) (protocol.Envelope, error) {
	for {
		env, err := c.r.Read()
		if err != nil {
			return env, fmt.Errorf("no reply from core: %w", err)
		}
		if env.ID != id {
			continue
		}
		if env.Type == protocol.TypeError {
			var e protocol.ErrorMsg
			_ = env.Decode(&e)
			return env, errors.New(e.Message)
		}
		return env, nil
	}
}

// snapshot subscribes, takes the snapshot and disconnects.
func snapshot() (protocol.Snapshot, error) {
	var snap protocol.Snapshot
	c, err := dialCore()
	if err != nil {
		return snap, err
	}
	defer c.Close()
	if err := c.w.Send(protocol.TypeSubscribe, "s", nil); err != nil {
		return snap, err
	}
	env, err := c.reply("s")
	if err != nil {
		return snap, err
	}
	if env.Type != protocol.TypeSnapshot {
		return snap, fmt.Errorf("unexpected reply %s", env.Type)
	}
	return snap, env.Decode(&snap)
}

func (a *app) status(_ context.Context, args []string) int {
	asJSON := false
	for _, arg := range args {
		if arg != "--json" {
			return a.usageErr("status", "unknown argument "+arg)
		}
		asJSON = true
	}
	snap, err := snapshot()
	if err != nil {
		return a.fail("status", err)
	}
	if asJSON {
		b, _ := json.MarshalIndent(snap, "", "  ")
		fmt.Fprintln(a.stdout, string(b))
		return 0
	}
	a.printStatus(snap)
	return 0
}

func (a *app) printStatus(s protocol.Snapshot) {
	w := a.stdout
	fmt.Fprintf(w, "PlatyNotch core (%s)\n", s.Edition)
	if len(s.Sessions) == 0 {
		fmt.Fprintln(w, "\nNo sessions")
	} else {
		fmt.Fprintln(w, "\nSessions:")
		for _, ss := range s.Sessions {
			fmt.Fprintf(w, "  %-12s %-14s %-16s %s\n", ss.AgentName, ss.State, orDash(ss.Project), ss.Title)
		}
	}
	if len(s.Approvals) > 0 {
		fmt.Fprintln(w, "\nPending approvals:")
		for _, ap := range s.Approvals {
			left := time.Until(ap.ExpiresAt).Round(time.Second)
			fmt.Fprintf(w, "  %s  %s %s: %s  (%s left)\n", ap.ID, ap.AgentName, ap.Tool, ap.Summary, left)
		}
	}
	if s.Usage.Claude != nil || s.Usage.Codex != nil {
		fmt.Fprintln(w, "\nUsage:")
		printLimits(a, "Claude", s.Usage.Claude)
		printLimits(a, "Codex", s.Usage.Codex)
	}
}

func printLimits(a *app, name string, l *protocol.Limits) {
	if l == nil {
		return
	}
	line := "  " + name + ":"
	if l.FiveHour != nil {
		line += fmt.Sprintf(" 5h %.0f%%", l.FiveHour.UsedPercent)
	}
	if l.Weekly != nil {
		line += fmt.Sprintf(" week %.0f%%", l.Weekly.UsedPercent)
	}
	fmt.Fprintln(a.stdout, line)
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
