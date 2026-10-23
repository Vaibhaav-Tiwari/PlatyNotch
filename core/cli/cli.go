// Package cli implements the `notch` command line: the core server, the agent
// hook client, the status line wrapper and a few commands for humans. The Pro
// edition builds its own binary on top of Run, adding extensions, commands and
// the memory engine through Options.
//
// Exit codes: 0 success, 1 runtime failure (e.g. the core is not running),
// 2 usage error (usage text on stderr). `hook` and `statusline` always exit 0
// so they can never break an agent.
package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	_ "github.com/Vaibhaav-Tiwari/PlatyNotch/core/agents/all" // register every adapter
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/ext"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/hookcli"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/paths"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/usage"
)

// Version is the release version, set at build time with
// -ldflags "-X github.com/Vaibhaav-Tiwari/PlatyNotch/core/cli.Version=1.2.3".
var Version = "dev"

// Command is a subcommand added by an embedding binary (e.g. Pro's `pair`).
type Command struct {
	Summary string
	Run     func(ctx context.Context, args []string) int
}

// Options configure Run; build them with the With* functions.
type Options struct {
	edition    string
	extensions []ext.Extension
	commands   map[string]Command
	openMemory func(config.Config) (memory.Service, error)
	stdin      io.Reader
	stdout     io.Writer
	stderr     io.Writer
}

type Option func(*Options)

// WithEdition sets the edition reported by `version` and in snapshots.
func WithEdition(e string) Option { return func(o *Options) { o.edition = e } }

// WithExtensions adds extensions started by `serve`.
func WithExtensions(e ...ext.Extension) Option {
	return func(o *Options) { o.extensions = append(o.extensions, e...) }
}

// WithCommands adds subcommands. A name that matches a built-in command
// replaces it.
func WithCommands(c map[string]Command) Option {
	return func(o *Options) {
		if o.commands == nil {
			o.commands = map[string]Command{}
		}
		for k, v := range c {
			o.commands[k] = v
		}
	}
}

// WithMemory sets the memory engine opener used by `serve`. It returns a nil
// Service when memory is off. Plan 2 passes its opener.
func WithMemory(open func(config.Config) (memory.Service, error)) Option {
	return func(o *Options) { o.openMemory = open }
}

// WithIO replaces os.Stdin/os.Stdout/os.Stderr (tests, embedding).
func WithIO(stdin io.Reader, stdout, stderr io.Writer) Option {
	return func(o *Options) { o.stdin, o.stdout, o.stderr = stdin, stdout, stderr }
}

// app is one invocation of Run.
type app struct {
	Options
	cmds map[string]Command
}

// Run executes the command line args (without the program name) and returns
// the process exit code.
func Run(ctx context.Context, args []string, opts ...Option) int {
	o := Options{edition: "free", stdin: os.Stdin, stdout: os.Stdout, stderr: os.Stderr}
	for _, opt := range opts {
		opt(&o)
	}
	a := &app{Options: o}
	a.cmds = map[string]Command{
		"serve":      {"run the core server (the Mac app starts it)", a.serve},
		"hook":       {"forward an agent hook event: hook <agent> <event>", a.hook},
		"statusline": {"Claude Code status line; statusline install|uninstall", a.statusline},
		"hooks":      {"manage agent hooks: hooks install|uninstall|status [agent|all] [--json]", a.hooks},
		"status":     {"show sessions, pending approvals and usage [--json]", a.status},
		"approve":    {"answer an approval: approve <id> allow|deny [--message m]", a.approve},
		"doctor":     {"check the core, agent hooks, status line and config", a.doctor},
		"version":    {"print the version", a.version},
	}
	for k, v := range o.commands {
		a.cmds[k] = v
	}

	if len(args) == 0 {
		a.usage(a.stderr)
		return 2
	}
	switch args[0] {
	case "help", "-h", "--help":
		a.usage(a.stdout)
		return 0
	}
	c, ok := a.cmds[args[0]]
	if !ok || c.Run == nil {
		fmt.Fprintf(a.stderr, "notch: unknown command %q\n", args[0])
		a.usage(a.stderr)
		return 2
	}
	return c.Run(ctx, args[1:])
}

func (a *app) usage(w io.Writer) {
	names := make([]string, 0, len(a.cmds))
	for n := range a.cmds {
		names = append(names, n)
	}
	sort.Strings(names)
	fmt.Fprintln(w, "usage: notch <command> [args]")
	fmt.Fprintln(w)
	for _, n := range names {
		fmt.Fprintf(w, "  %-11s %s\n", n, a.cmds[n].Summary)
	}
}

// synopsis is each built-in command's argument syntax.
var synopsis = map[string]string{
	"serve":      "serve",
	"hook":       "hook <agent> <event>",
	"statusline": "statusline [install|uninstall]",
	"hooks":      "hooks install|uninstall|status [agent|all] [--json]",
	"status":     "status [--json]",
	"approve":    "approve <id> allow|deny [--message m]",
	"doctor":     "doctor",
	"version":    "version",
}

// usageErr prints a usage error for one command and returns 2.
func (a *app) usageErr(cmd, msg string) int {
	fmt.Fprintf(a.stderr, "notch %s: %s\nusage: notch %s\n", cmd, msg, synopsis[cmd])
	return 2
}

// fail prints a runtime error and returns 1.
func (a *app) fail(cmd string, err error) int {
	fmt.Fprintf(a.stderr, "notch %s: %v\n", cmd, err)
	return 1
}

func (a *app) version(_ context.Context, args []string) int {
	if len(args) != 0 {
		return a.usageErr("version", "takes no arguments")
	}
	fmt.Fprintf(a.stdout, "notch %s (%s)\n", Version, a.edition)
	return 0
}

// hook never fails: wrong arguments or an unreachable core print nothing.
func (a *app) hook(_ context.Context, args []string) int {
	if len(args) != 2 {
		_, _ = io.Copy(io.Discard, a.stdin)
		return 0
	}
	return hookcli.Run(args[0], args[1], a.stdin, a.stdout, os.Getenv)
}

func (a *app) statusline(_ context.Context, args []string) int {
	if len(args) == 0 {
		cfg, _ := config.Load() // on error Load returns defaults
		return usage.RunStatusline(a.stdin, a.stdout, cfg)
	}
	if len(args) != 1 {
		return a.usageErr("statusline", "too many arguments")
	}
	switch args[0] {
	case "install":
		bin, err := ensureHookBinary()
		if err != nil {
			return a.fail("statusline", err)
		}
		if err := usage.InstallStatusline(bin); err != nil {
			return a.fail("statusline", err)
		}
		fmt.Fprintln(a.stdout, "Claude Code status line installed")
	case "uninstall":
		if err := usage.UninstallStatusline(); err != nil {
			return a.fail("statusline", err)
		}
		fmt.Fprintln(a.stdout, "Claude Code status line uninstalled")
	default:
		return a.usageErr("statusline", "unknown subcommand "+args[0])
	}
	return 0
}

// ensureHookBinary returns paths.HookBinary(), the stable path written into
// agent configs. When nothing is there (or only a dangling symlink) it links
// it to this executable so the standalone CLI works before the Mac app exists;
// the app re-points it later. An existing file or live symlink is kept.
func ensureHookBinary() (string, error) {
	p := paths.HookBinary()
	if st, err := os.Lstat(p); err == nil {
		if st.Mode()&os.ModeSymlink == 0 {
			return p, nil
		}
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
		if err := os.Remove(p); err != nil { // dangling symlink
			return "", err
		}
	}
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locate notch binary: %w", err)
	}
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return "", err
	}
	if err := os.Symlink(exe, p); err != nil && !os.IsExist(err) {
		return "", err
	}
	return p, nil
}
