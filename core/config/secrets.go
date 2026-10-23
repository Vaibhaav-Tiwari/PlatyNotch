package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strconv"
	"sync"
)

// SecretsFDEnv names the inherited file descriptor on which the Mac app
// writes {"<keychain account>": "<secret>"} for every keychain: reference in
// config.json before closing it. The app reads its own Keychain items, so
// the core never has to run /usr/bin/security (whose access prompt names
// "security", not PlatyNotch). Only `notch serve` reads it; the CLI and
// `notch mcp` keep the security fallback.
const SecretsFDEnv = "PLATYNOTCH_SECRETS_FD"

// MaxInheritedSecrets caps what is read from the descriptor.
const MaxInheritedSecrets = 64 << 10

var (
	secretsMu sync.RWMutex
	inherited map[string]string
)

// LoadInheritedSecrets reads the descriptor named by PLATYNOTCH_SECRETS_FD
// once, closes it and unsets the variable (so child processes never see it).
// Without the variable it does nothing. Errors never contain secret text.
func LoadInheritedSecrets() error {
	v, ok := os.LookupEnv(SecretsFDEnv)
	if !ok {
		return nil
	}
	_ = os.Unsetenv(SecretsFDEnv)
	fd, err := strconv.Atoi(v)
	if err != nil || fd < 0 {
		return errors.New(SecretsFDEnv + " is not a file descriptor number")
	}
	f := os.NewFile(uintptr(fd), "inherited-secrets")
	if f == nil {
		return errors.New(SecretsFDEnv + " is not an open file descriptor")
	}
	defer f.Close()
	return loadSecretsFrom(f)
}

func loadSecretsFrom(r io.Reader) error {
	b, err := io.ReadAll(io.LimitReader(r, MaxInheritedSecrets+1))
	if err != nil {
		return errors.New("cannot read inherited secrets")
	}
	if len(b) > MaxInheritedSecrets {
		return errors.New("inherited secrets exceed 64 KB; ignored")
	}
	m := map[string]string{}
	if len(bytes.TrimSpace(b)) > 0 {
		if json.Unmarshal(b, &m) != nil {
			// The decoder's error could quote input; never pass it on.
			return errors.New("inherited secrets are not a JSON object of strings; ignored")
		}
	}
	secretsMu.Lock()
	inherited = m
	secretsMu.Unlock()
	return nil
}

func inheritedSecret(account string) (string, bool) {
	secretsMu.RLock()
	defer secretsMu.RUnlock()
	s, ok := inherited[account]
	return s, ok
}

// InheritedSecretCount reports how many secrets were handed over (for logs).
func InheritedSecretCount() int {
	secretsMu.RLock()
	defer secretsMu.RUnlock()
	return len(inherited)
}
