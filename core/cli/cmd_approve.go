package cli

import (
	"context"
	"fmt"
	"strings"

	"github.com/platynotch/platynotch/core/protocol"
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
	if err := c.w.Send(protocol.TypeApprovalDecide, "d", d); err != nil {
		return a.fail("approve", err)
	}
	if err := c.w.Send(protocol.TypePing, "p", nil); err != nil {
		return a.fail("approve", err)
	}
	for {
		env, err := c.r.Read()
		if err != nil {
			return a.fail("approve", fmt.Errorf("no reply from core: %w", err))
		}
		switch {
		case env.ID == "d" && env.Type == protocol.TypeError:
			var e protocol.ErrorMsg
			_ = env.Decode(&e)
			return a.fail("approve", fmt.Errorf("%s: %s", id, e.Message))
		case env.ID == "p" && env.Type == protocol.TypePong:
			fmt.Fprintf(a.stdout, "%s: %s\n", id, behavior)
			return 0
		}
	}
}
