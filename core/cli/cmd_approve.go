package cli

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// approve <id> allow|deny [--message m]. The core replies to approval.decide
// only on error, so a ping follows it: per-connection messages are handled in
// order, so the pong arriving first means the decision was accepted.
func (a *app) approve(_ context.Context, args []string) int {
	var pos []string
	msg := ""
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--message" || arg == "-m":
			if i+1 >= len(args) {
				return a.usageErr("approve", arg+" needs a value")
			}
			i++
			msg = args[i]
		case strings.HasPrefix(arg, "--message="):
			msg = strings.TrimPrefix(arg, "--message=")
		case strings.HasPrefix(arg, "-") && len(arg) > 1:
			return a.usageErr("approve", "unknown flag "+arg)
		default:
			pos = append(pos, arg)
		}
	}
	if len(pos) != 2 {
		return a.usageErr("approve", "expected an approval id and allow or deny")
	}
	id, behavior := pos[0], pos[1]
	if behavior != protocol.BehaviorAllow && behavior != protocol.BehaviorDeny {
		return a.usageErr("approve", fmt.Sprintf("behavior must be allow or deny, got %q", behavior))
	}

	c, err := dialCore()
	if err != nil {
		return a.fail("approve", err)
	}
	defer c.Close()
	d := protocol.ApprovalDecide{ID: id, Behavior: behavior, Message: msg, Source: "cli"}
	if err := c.sendConfirmed(protocol.TypeApprovalDecide, d); err != nil {
		return a.fail("approve", fmt.Errorf("%s: %w", id, err))
	}
	fmt.Fprintf(a.stdout, "%s: %s\n", id, behavior)
	return 0
}

// sendConfirmed sends one message the core answers only on error, then a ping:
// per-connection messages are handled in order, so the pong arriving first
// means the message was accepted. A core error reply becomes the returned
// error.
func (c *coreConn) sendConfirmed(typ string, payload any) error {
	if err := c.w.Send(typ, "d", payload); err != nil {
		return err
	}
	if err := c.w.Send(protocol.TypePing, "p", nil); err != nil {
		return err
	}
	for {
		env, err := c.r.Read()
		if err != nil {
			return fmt.Errorf("no reply from core: %w", err)
		}
		switch {
		case env.ID == "d" && env.Type == protocol.TypeError:
			var e protocol.ErrorMsg
			_ = env.Decode(&e)
			return errors.New(e.Message)
		case env.ID == "p" && env.Type == protocol.TypePong:
			return nil
		}
	}
}

// sendAwaitReply sends one message and waits for the reply carrying id: an
// error reply becomes the returned error, any other type with that id is
// success. For handlers that always answer (loop.set_status).
func (c *coreConn) sendAwaitReply(typ, id string, payload any, timeout time.Duration) error {
	if err := c.w.Send(typ, id, payload); err != nil {
		return err
	}
	_ = c.nc.SetReadDeadline(time.Now().Add(timeout))
	for {
		env, err := c.r.Read()
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				return errNoAnswer
			}
			return fmt.Errorf("no reply from core: %w", err)
		}
		if env.ID != id {
			continue
		}
		if env.Type == protocol.TypeError {
			var e protocol.ErrorMsg
			_ = env.Decode(&e)
			return errors.New(e.Message)
		}
		return nil
	}
}

var errNoAnswer = errors.New("PlatyNotch did not answer.")
