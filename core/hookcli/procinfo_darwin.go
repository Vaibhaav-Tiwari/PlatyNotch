//go:build darwin

package hookcli

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func psOut(args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ps", args...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func parentOf(pid int) int {
	n, err := strconv.Atoi(psOut("-o", "ppid=", "-p", strconv.Itoa(pid)))
	if err != nil {
		return 0
	}
	return n
}

func ttyOf(pid int) string {
	t := psOut("-o", "tty=", "-p", strconv.Itoa(pid))
	if t == "??" || t == "?" {
		return ""
	}
	return t
}

// procName is the process's command name (`ps -o comm=`), e.g. "/bin/zsh" or "-zsh".
func procName(pid int) string { return psOut("-o", "comm=", "-p", strconv.Itoa(pid)) }
