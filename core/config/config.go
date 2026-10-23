// Package config loads ~/Library/Application Support/PlatyNotch/config.json.
// The Mac app writes this file from its Settings window; the core re-reads it
// on config.reload. Secrets never live here: they are read from the macOS
// Keychain (service "PlatyNotch") or from an environment variable.
package config

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/platynotch/platynotch/core/paths"
)

type Config struct {
	Approvals  Approvals  `json:"approvals"`
	Policy     Policy     `json:"policy"`
	Memory     Memory     `json:"memory"`
	Statusline Statusline `json:"statusline"`
	// Pro holds settings owned by the Pro edition; the free core ignores it.
	Pro json.RawMessage `json:"pro,omitempty"`
}

type Approvals struct {
	Enabled        bool            `json:"enabled"`
	TimeoutSeconds int             `json:"timeout_seconds"` // how long a hook waits for a click
	Agents         map[string]bool `json:"agents"`          // adapter id → approvals on
}

// Policy rules are enforced locally by the core before a prompt is shown.
type Policy struct {
	Rules []Rule `json:"rules"`
}

// Rule matches a tool call. Tool is an exact tool name ("Bash", "Write") or "*".
// Pattern is a glob ("*" any run incl. "/" and spaces, "?" one char) against the
// approval summary (the command or file path).
type Rule struct {
	Tool    string `json:"tool"`
	Pattern string `json:"pattern"`
	Action  string `json:"action"` // "allow" | "deny" | "ask"
	Reason  string `json:"reason,omitempty"`
}

type Memory struct {
	Enabled                bool     `json:"enabled"`
	CaptureIntervalSeconds int      `json:"capture_interval_seconds"`
	ExcludeApps            []string `json:"exclude_apps"` // bundle ids never captured
	RetentionDays          int      `json:"retention_days"`
	Embedder               Provider `json:"embedder"`
	Extractor              Provider `json:"extractor"`
}

// Provider selects an AI backend. Built-in providers: "none", "ollama",
// "openai" (any OpenAI-compatible endpoint). Pro registers "platynotch-cloud".
type Provider struct {
	Name    string `json:"name"`
	Model   string `json:"model,omitempty"`
	BaseURL string `json:"base_url,omitempty"`
	// APIKeyRef names the secret: "keychain:<account>" or "env:<VAR>".
	APIKeyRef string `json:"api_key_ref,omitempty"`
}

type Statusline struct {
	// Previous is the user's own statusLine command, run after ours.
	Previous string `json:"previous,omitempty"`
}

// Default is the configuration used when no file exists.
func Default() Config {
	return Config{
		Approvals: Approvals{
			Enabled:        true,
			TimeoutSeconds: 100,
			Agents:         map[string]bool{"claude-code": true},
		},
		Policy: Policy{Rules: DefaultRules()},
		Memory: Memory{
			Enabled:                false,
			CaptureIntervalSeconds: 20,
			RetentionDays:          90,
			ExcludeApps: []string{
				"com.1password.1password", "com.agilebits.onepassword7",
				"com.apple.keychainaccess", "com.bitwarden.desktop",
				"com.apple.Passwords", "com.lastpass.LastPass",
			},
			Embedder:  Provider{Name: "none"},
			Extractor: Provider{Name: "none"},
		},
	}
}

// DefaultRules deny a few commands nobody should approve by accident.
func DefaultRules() []Rule {
	return []Rule{
		{Tool: "Bash", Pattern: "rm -rf /*", Action: "deny", Reason: "Deletes from the filesystem root."},
		{Tool: "Bash", Pattern: "rm -rf ~*", Action: "deny", Reason: "Deletes the home directory."},
		{Tool: "Bash", Pattern: "*git push*--force*", Action: "ask", Reason: "Force push rewrites shared history."},
	}
}

// Load reads the config file, filling missing fields from Default.
func Load() (Config, error) {
	return LoadFile(paths.Config())
}

func LoadFile(path string) (Config, error) {
	cfg := Default()
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return cfg, nil
	}
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return Default(), err
	}
	if cfg.Approvals.TimeoutSeconds <= 0 {
		cfg.Approvals.TimeoutSeconds = 100
	}
	if cfg.Approvals.Agents == nil {
		cfg.Approvals.Agents = map[string]bool{}
	}
	if cfg.Memory.CaptureIntervalSeconds <= 0 {
		cfg.Memory.CaptureIntervalSeconds = 20
	}
	if cfg.Memory.Embedder.Name == "" {
		cfg.Memory.Embedder.Name = "none"
	}
	if cfg.Memory.Extractor.Name == "" {
		cfg.Memory.Extractor.Name = "none"
	}
	return cfg, nil
}

// Save writes the config atomically with owner-only permissions.
func Save(cfg Config) error { return SaveFile(paths.Config(), cfg) }

func SaveFile(path string, cfg Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ApprovalsOn reports whether approvals are enabled for an adapter.
func (c Config) ApprovalsOn(agent string) bool {
	return c.Approvals.Enabled && c.Approvals.Agents[agent]
}

// Secret resolves an APIKeyRef. Empty ref → empty string, no error.
func Secret(ref string) (string, error) {
	switch {
	case ref == "":
		return "", nil
	case strings.HasPrefix(ref, "env:"):
		return os.Getenv(strings.TrimPrefix(ref, "env:")), nil
	case strings.HasPrefix(ref, "keychain:"):
		account := strings.TrimPrefix(ref, "keychain:")
		out, err := exec.Command("/usr/bin/security", "find-generic-password",
			"-s", "PlatyNotch", "-a", account, "-w").Output()
		if err != nil {
			return "", errors.New("keychain item PlatyNotch/" + account + " not found")
		}
		return strings.TrimSpace(string(out)), nil
	default:
		return "", errors.New("unknown secret reference " + ref)
	}
}
