package config

import (
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
)

func resetSecrets(t *testing.T) {
	t.Helper()
	orig := keychainLookup
	t.Cleanup(func() {
		keychainLookup = orig
		secretsMu.Lock()
		inherited = nil
		secretsMu.Unlock()
	})
}

func TestSecretPrefersInheritedMap(t *testing.T) {
	resetSecrets(t)
	var asked []string
	keychainLookup = func(account string) (string, error) {
		asked = append(asked, account)
		return "from-security", nil
	}
	if err := loadSecretsFrom(strings.NewReader(`{"embedder.openai":"sk-emb","extractor.openai":"sk-ext"}`)); err != nil {
		t.Fatal(err)
	}
	for ref, want := range map[string]string{"keychain:embedder.openai": "sk-emb", "keychain:extractor.openai": "sk-ext"} {
		got, err := Secret(ref)
		if err != nil || got != want {
			t.Fatalf("Secret(%q) = %q, %v; want %q", ref, got, err, want)
		}
	}
	if len(asked) != 0 {
		t.Fatalf("security was run for %v; the inherited map must be used", asked)
	}
	// A missing account falls back to security.
	if got, err := Secret("keychain:other"); err != nil || got != "from-security" || len(asked) != 1 || asked[0] != "other" {
		t.Fatalf("fallback: %q %v %v", got, err, asked)
	}
}

func TestSecretFallbackErrorNamesAccountOnly(t *testing.T) {
	resetSecrets(t)
	keychainLookup = func(string) (string, error) { return "", errors.New("exit 44") }
	_, err := Secret("keychain:embedder.openai")
	if err == nil || !strings.Contains(err.Error(), "embedder.openai") {
		t.Fatalf("err = %v", err)
	}
}

func TestLoadInheritedSecretsFromFD(t *testing.T) {
	resetSecrets(t)
	keychainLookup = func(string) (string, error) { t.Fatal("security must not run"); return "", nil }
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.WriteString(`{"embedder.openai":"sk-1"}`); err != nil {
		t.Fatal(err)
	}
	w.Close()
	t.Setenv(SecretsFDEnv, strconv.Itoa(int(r.Fd())))
	if err := LoadInheritedSecrets(); err != nil {
		t.Fatal(err)
	}
	if _, set := os.LookupEnv(SecretsFDEnv); set {
		t.Fatal("env var must be unset after reading")
	}
	if got, _ := Secret("keychain:embedder.openai"); got != "sk-1" {
		t.Fatalf("got %q", got)
	}
	if InheritedSecretCount() != 1 {
		t.Fatal("count")
	}
}

func TestLoadInheritedSecretsRejectsBadInputWithoutEchoingIt(t *testing.T) {
	resetSecrets(t)
	big := `{"a":"` + strings.Repeat("x", MaxInheritedSecrets) + `"}`
	if err := loadSecretsFrom(strings.NewReader(big)); err == nil {
		t.Fatal("oversize accepted")
	}
	err := loadSecretsFrom(strings.NewReader(`{"a": sk-SECRET}`))
	if err == nil || strings.Contains(err.Error(), "SECRET") {
		t.Fatalf("err = %v", err)
	}
	if err := loadSecretsFrom(strings.NewReader("")); err != nil || InheritedSecretCount() != 0 {
		t.Fatalf("empty input: %v", err)
	}
	t.Setenv(SecretsFDEnv, "nope")
	if err := LoadInheritedSecrets(); err == nil {
		t.Fatal("bad fd accepted")
	}
}

func TestNoEnvIsNoop(t *testing.T) {
	resetSecrets(t)
	os.Unsetenv(SecretsFDEnv)
	if err := LoadInheritedSecrets(); err != nil || InheritedSecretCount() != 0 {
		t.Fatal(err)
	}
}
