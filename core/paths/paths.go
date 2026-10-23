// Package paths resolves every file location PlatyNotch uses. All of them can
// be redirected with PLATYNOTCH_HOME so tests and Pro builds never touch the
// user's real data.
package paths

import (
	"os"
	"path/filepath"
)

// Home returns the PlatyNotch data directory
// (~/Library/Application Support/PlatyNotch by default).
func Home() string {
	if h := os.Getenv("PLATYNOTCH_HOME"); h != "" {
		return h
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = filepath.Join(UserHome(), "Library", "Application Support")
	}
	return filepath.Join(dir, "PlatyNotch")
}

// UserHome is the user's home directory; PLATYNOTCH_USER_HOME overrides it so
// tests can install hooks into a fake home.
func UserHome() string {
	if h := os.Getenv("PLATYNOTCH_USER_HOME"); h != "" {
		return h
	}
	h, _ := os.UserHomeDir()
	return h
}

// Socket is the core's Unix socket. Kept short: macOS caps socket paths at 104 bytes.
func Socket() string {
	if s := os.Getenv("PLATYNOTCH_SOCKET"); s != "" {
		return s
	}
	return filepath.Join(Home(), "notch.sock")
}

func Config() string    { return filepath.Join(Home(), "config.json") }
func MemoryDB() string  { return filepath.Join(Home(), "memory.db") }
func UsageFile() string { return filepath.Join(Home(), "usage.json") }
func LogDir() string    { return filepath.Join(Home(), "logs") }
func BinDir() string    { return filepath.Join(Home(), "bin") }

// HookBinary is the stable path written into agent configs. The app keeps it
// symlinked to the binary inside the current app bundle, so hooks survive the
// app being moved or updated.
func HookBinary() string { return filepath.Join(BinDir(), "notch") }

// EnsureHome creates the data directory with owner-only permissions.
func EnsureHome() error {
	if err := os.MkdirAll(Home(), 0o700); err != nil {
		return err
	}
	return os.MkdirAll(LogDir(), 0o700)
}
