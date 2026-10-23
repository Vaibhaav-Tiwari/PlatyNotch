package mcpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/hookjson"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
)

// Clients that `notch mcp install` can register PlatyNotch with.
const (
	ClientClaudeDesktop = "claude-desktop"
	ClientClaudeCode    = "claude-code"
	ClientCursor        = "cursor"
)

// Clients lists the supported client names.
var Clients = []string{ClientClaudeDesktop, ClientClaudeCode, ClientCursor}

// ServerName is the key PlatyNotch registers under in every client.
const ServerName = "platynotch"

// Runner runs an external command and returns its combined output.
type Runner func(ctx context.Context, name string, args ...string) ([]byte, error)

// ExecRunner runs commands for real.
func ExecRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

// ConfigPath is the MCP config file for a JSON-configured client
// (claude-desktop, cursor), under paths.UserHome().
func ConfigPath(client string) (string, bool) {
	switch client {
	case ClientClaudeDesktop:
		return filepath.Join(paths.UserHome(), "Library", "Application Support", "Claude", "claude_desktop_config.json"), true
	case ClientCursor:
		return filepath.Join(paths.UserHome(), ".cursor", "mcp.json"), true
	}
	return "", false
}

// Install registers `<hookBin> mcp` as the "platynotch" MCP server in client
// and returns a human-readable result line. JSON clients get
// mcpServers.platynotch merged in (other servers and keys kept, a one-time
// .platynotch-backup, atomic write). claude-code goes through the `claude`
// CLI when it is on PATH; otherwise nothing is run and the returned line holds
// the exact command for the user. A nil run uses ExecRunner.
func Install(ctx context.Context, client, hookBin string, run Runner) (string, error) {
	if hookBin == "" {
		return "", errors.New("mcp install: binary path is required")
	}
	if run == nil {
		run = ExecRunner
	}
	if client == ClientClaudeCode {
		return claudeCode(ctx, run, true, hookBin)
	}
	p, ok := ConfigPath(client)
	if !ok {
		return "", unknownClient(client)
	}
	entry, err := json.Marshal(struct {
		Command string   `json:"command"`
		Args    []string `json:"args"`
	}{hookBin, []string{"mcp"}})
	if err != nil {
		return "", err
	}
	changed, err := hookjson.SetNested(p, "mcpServers", ServerName, entry)
	if err != nil {
		return "", err
	}
	if !changed {
		return fmt.Sprintf("%s: PlatyNotch MCP server already registered in %s", client, p), nil
	}
	return fmt.Sprintf("%s: PlatyNotch MCP server registered in %s (restart %s to load it)", client, p, appName(client)), nil
}

// Uninstall removes the "platynotch" MCP server from client. A missing config
// file or entry is a no-op.
func Uninstall(ctx context.Context, client string, run Runner) (string, error) {
	if run == nil {
		run = ExecRunner
	}
	if client == ClientClaudeCode {
		return claudeCode(ctx, run, false, "")
	}
	p, ok := ConfigPath(client)
	if !ok {
		return "", unknownClient(client)
	}
	changed, err := hookjson.SetNested(p, "mcpServers", ServerName, nil)
	if err != nil {
		return "", err
	}
	if !changed {
		return fmt.Sprintf("%s: PlatyNotch MCP server was not registered", client), nil
	}
	return fmt.Sprintf("%s: PlatyNotch MCP server removed from %s", client, p), nil
}

func unknownClient(c string) error {
	return fmt.Errorf("unknown client %q (one of: %s)", c, strings.Join(Clients, ", "))
}

func appName(client string) string {
	if client == ClientCursor {
		return "Cursor"
	}
	return "Claude Desktop"
}

// claudeCode registers or removes the server with Claude Code's own CLI at
// user scope. Install first removes any previous registration (ignoring a
// failure) so a re-install re-points it instead of failing with "already
// exists".
func claudeCode(ctx context.Context, run Runner, install bool, hookBin string) (string, error) {
	remove := []string{"mcp", "remove", "--scope", "user", ServerName}
	add := []string{"mcp", "add", "--scope", "user", ServerName, "--", hookBin, "mcp"}
	args := remove
	if install {
		args = add
	}
	claude, err := exec.LookPath("claude")
	if err != nil {
		return fmt.Sprintf("claude-code: the claude CLI is not on PATH, so this was not run. Run it yourself:\n  %s", shellJoin("claude", args)), nil
	}
	if !install {
		out, err := run(ctx, claude, remove...)
		if err != nil {
			if notRegistered(out) {
				return "claude-code: PlatyNotch MCP server was not registered", nil
			}
			return "", fmt.Errorf("claude %s: %v: %s", strings.Join(remove, " "), err, bytes.TrimSpace(out))
		}
		return "claude-code: PlatyNotch MCP server removed (user scope)", nil
	}
	_, _ = run(ctx, claude, remove...)
	out, err := run(ctx, claude, add...)
	if err != nil {
		return "", fmt.Errorf("claude %s: %v: %s", strings.Join(add, " "), err, bytes.TrimSpace(out))
	}
	return "claude-code: PlatyNotch MCP server registered (user scope)", nil
}

// notRegistered recognises `claude mcp remove` failing only because there is
// nothing to remove ("No user-scoped MCP server found with name: …").
func notRegistered(out []byte) bool {
	s := strings.ToLower(string(out))
	return strings.Contains(s, "no ") && strings.Contains(s, "found")
}

// shellJoin renders a command line a user can paste into a POSIX shell.
func shellJoin(name string, args []string) string {
	parts := []string{shellQuote(name)}
	for _, a := range args {
		parts = append(parts, shellQuote(a))
	}
	return strings.Join(parts, " ")
}

func shellQuote(s string) string {
	if s != "" && strings.IndexFunc(s, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("-_./=:@+,", r))
	}) < 0 {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
