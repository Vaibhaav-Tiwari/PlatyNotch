package usage

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/platynotch/platynotch/core/config"
	"github.com/platynotch/platynotch/core/hookjson"
	"github.com/platynotch/platynotch/core/protocol"
)

func fx(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func env(t *testing.T) (home, user string) {
	t.Helper()
	home, user = t.TempDir(), t.TempDir()
	t.Setenv("PLATYNOTCH_HOME", home)
	t.Setenv("PLATYNOTCH_USER_HOME", user)
	return
}

func TestStatuslineNestedLimits(t *testing.T) {
	l, ok := ParseStatusline(fx(t, "claude_statusline.json"))
	if !ok || l.FiveHour == nil || l.Weekly == nil {
		t.Fatalf("%+v %v", l, ok)
	}
	if l.FiveHour.UsedPercent != 42 || l.FiveHour.ResetsAt == nil || l.FiveHour.ResetsAt.Unix() != 1800000000 {
		t.Fatalf("five hour %+v", l.FiveHour)
	}
	if l.Weekly.UsedPercent != 8.5 || l.Weekly.ResetsAt == nil || l.Weekly.ResetsAt.UTC().Format(time.RFC3339) != "2027-01-15T08:00:00Z" {
		t.Fatalf("weekly %+v", l.Weekly)
	}
	if o, ok := l.Extra["seven_day_opus"]; !ok || o.UsedPercent != 3 {
		t.Fatalf("extra %+v", l.Extra)
	}
	if l.UpdatedAt.IsZero() {
		t.Fatal("UpdatedAt not set")
	}
}

func TestStatuslineFractions(t *testing.T) {
	l, ok := ParseStatusline(fx(t, "claude_statusline_fraction.json"))
	if !ok || l.FiveHour == nil || l.FiveHour.UsedPercent != 42 || l.Weekly.UsedPercent != 10 {
		t.Fatalf("%+v %v", l, ok)
	}
}

func TestStatuslineNoLimits(t *testing.T) {
	if l, ok := ParseStatusline(fx(t, "claude_statusline_none.json")); ok || l != nil {
		t.Fatalf("%+v %v", l, ok)
	}
	if _, ok := ParseStatusline([]byte("not json")); ok {
		t.Fatal("garbage parsed")
	}
}

func TestRunsPreviousCommand(t *testing.T) {
	env(t)
	cfg := config.Default()
	cfg.Statusline.Previous = "echo hi; echo oops >&2"
	var out bytes.Buffer
	if code := RunStatusline(bytes.NewReader(fx(t, "claude_statusline.json")), &out, cfg); code != 0 {
		t.Fatal(code)
	}
	if strings.TrimSpace(out.String()) != "hi" {
		t.Fatalf("stdout %q", out.String())
	}
	// usage.json written
	b, err := os.ReadFile(filepath.Join(os.Getenv("PLATYNOTCH_HOME"), "usage.json"))
	if err != nil {
		t.Fatal(err)
	}
	var l protocol.Limits
	if json.Unmarshal(b, &l) != nil || l.FiveHour == nil || l.FiveHour.UsedPercent != 42 {
		t.Fatalf("usage.json %s", b)
	}
}

func TestPreviousReceivesStdin(t *testing.T) {
	env(t)
	cfg := config.Default()
	cfg.Statusline.Previous = "cat"
	var out bytes.Buffer
	in := fx(t, "claude_statusline_none.json")
	RunStatusline(bytes.NewReader(in), &out, cfg)
	if out.String() != string(in) {
		t.Fatalf("%q", out.String())
	}
}

func TestDefaultLineAndFailureFallback(t *testing.T) {
	env(t)
	for _, prev := range []string{"", "exit 3", "printf %s \"\""} {
		cfg := config.Default()
		cfg.Statusline.Previous = prev
		var out bytes.Buffer
		if code := RunStatusline(bytes.NewReader(fx(t, "claude_statusline.json")), &out, cfg); code != 0 {
			t.Fatal(code)
		}
		if strings.TrimSpace(out.String()) != "Opus · 5h 42%" {
			t.Fatalf("prev %q: %q", prev, out.String())
		}
	}
	var out bytes.Buffer
	if RunStatusline(strings.NewReader("garbage"), &out, config.Default()) != 0 || strings.TrimSpace(out.String()) == "" {
		t.Fatalf("garbage: %q", out.String())
	}
}

func TestPreviousTimeout(t *testing.T) {
	env(t)
	cfg := config.Default()
	cfg.Statusline.Previous = "sleep 30"
	var out bytes.Buffer
	start := time.Now()
	RunStatusline(bytes.NewReader(fx(t, "claude_statusline.json")), &out, cfg)
	if time.Since(start) > 5*time.Second || !strings.Contains(out.String(), "Opus") {
		t.Fatalf("%v %q", time.Since(start), out.String())
	}
}

func TestCodexRollout(t *testing.T) {
	var lines [][]byte
	for _, ln := range bytes.Split(fx(t, "codex_rollout.jsonl"), []byte("\n")) {
		lines = append(lines, ln)
	}
	now = func() time.Time { return time.Unix(1800000000, 0) }
	defer func() { now = time.Now }()
	l, ok := ParseCodexRollout(lines)
	if !ok || l.FiveHour == nil || l.Weekly == nil {
		t.Fatalf("%+v %v", l, ok)
	}
	if l.FiveHour.UsedPercent != 37 || l.FiveHour.ResetsAt.Unix() != 1800005400 {
		t.Fatalf("5h %+v", l.FiveHour)
	}
	if l.Weekly.UsedPercent != 12.5 || l.Weekly.ResetsAt.Unix() != 1800600000 {
		t.Fatalf("weekly %+v", l.Weekly)
	}
	if _, ok := ParseCodexRollout([][]byte{[]byte(`{"type":"x"}`), []byte("junk")}); ok {
		t.Fatal("no rate_limits should be false")
	}
}

func TestInstallRestoresPrevious(t *testing.T) {
	_, user := env(t)
	settings := filepath.Join(user, ".claude", "settings.json")
	os.MkdirAll(filepath.Dir(settings), 0o755)
	// 2-space canonical form, so a faithful restore is byte-identical.
	orig := `{
  "model": "opus",
  "statusLine": {
    "type": "command",
    "command": "~/bin/my-status.sh",
    "padding": 0
  },
  "env": {
    "A": "1"
  }
}
`
	os.WriteFile(settings, []byte(orig), 0o644)
	bin := "/Users/x/Library/Application Support/PlatyNotch/bin/notch"

	for i := 0; i < 2; i++ { // second install must not overwrite Previous
		if err := InstallStatusline(bin); err != nil {
			t.Fatal(err)
		}
	}
	raw, _, _ := hookjson.GetTopLevel(settings, "statusLine")
	if !strings.Contains(string(raw), `notch\" statusline`) {
		t.Fatalf("not installed: %s", raw)
	}
	cfg, _ := config.Load()
	if cfg.Statusline.Previous != "~/bin/my-status.sh" {
		t.Fatalf("previous %q", cfg.Statusline.Previous)
	}
	if err := UninstallStatusline(); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(settings); string(b) != orig {
		t.Fatalf("not restored byte-for-byte:\n%s", b)
	}
	cfg, _ = config.Load()
	if cfg.Statusline.Previous != "" || len(cfg.Statusline.PreviousRaw) != 0 {
		t.Fatalf("previous not cleared: %+v", cfg.Statusline)
	}
}

func TestInstallWithoutPreviousThenUninstallRemoves(t *testing.T) {
	_, user := env(t)
	settings := filepath.Join(user, ".claude", "settings.json")
	os.MkdirAll(filepath.Dir(settings), 0o755)
	orig := `{
  "model": "opus",
  "env": {
    "A": "1"
  }
}
`
	os.WriteFile(settings, []byte(orig), 0o644)
	if err := InstallStatusline("/x/notch"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := hookjson.GetTopLevel(settings, "statusLine"); !ok {
		t.Fatal("not installed")
	}
	if err := UninstallStatusline(); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(settings); string(b) != orig {
		t.Fatalf("rest of file changed:\n%s", b)
	}
}

func TestInstallWithoutSettingsThenUninstallRemoves(t *testing.T) {
	_, user := env(t)
	settings := filepath.Join(user, ".claude", "settings.json")
	if err := InstallStatusline("/x/notch"); err != nil {
		t.Fatal(err)
	}
	if err := UninstallStatusline(); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := hookjson.GetTopLevel(settings, "statusLine"); ok {
		t.Fatal("statusLine should be removed")
	}
}

func TestUninstallLeavesForeignStatusLine(t *testing.T) {
	_, user := env(t)
	settings := filepath.Join(user, ".claude", "settings.json")
	os.MkdirAll(filepath.Dir(settings), 0o755)
	os.WriteFile(settings, []byte(`{"statusLine":{"type":"command","command":"foo"}}`), 0o644)
	if err := UninstallStatusline(); err != nil {
		t.Fatal(err)
	}
	raw, ok, _ := hookjson.GetTopLevel(settings, "statusLine")
	if !ok || !strings.Contains(string(raw), "foo") {
		t.Fatalf("%s", raw)
	}
}

func TestWatcher(t *testing.T) {
	home := t.TempDir()
	usageFile := filepath.Join(home, "usage.json")
	sessions := filepath.Join(home, "sessions")
	day := filepath.Join(sessions, "2026", "10", "23")
	os.MkdirAll(day, 0o755)
	old := filepath.Join(day, "rollout-old.jsonl")
	os.WriteFile(old, []byte(`{"payload":{"rate_limits":{"primary":{"used_percent":99,"window_minutes":300,"resets_at":1800000000}}}}`+"\n"), 0o644)
	os.Chtimes(old, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour))
	newer := filepath.Join(day, "rollout-new.jsonl")
	os.WriteFile(newer, fx(t, "codex_rollout.jsonl"), 0o644)

	var mu sync.Mutex
	var got []protocol.Usage
	w := NewWatcher(usageFile, sessions, func(u protocol.Usage) {
		mu.Lock()
		got = append(got, u)
		mu.Unlock()
	})
	w.Interval = 10 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { w.Run(ctx); close(done) }()
	defer func() { cancel(); <-done }()

	waitFor := func(cond func() bool) {
		t.Helper()
		for i := 0; i < 300; i++ {
			mu.Lock()
			ok := cond()
			mu.Unlock()
			if ok {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("timed out")
	}
	waitFor(func() bool { return len(got) == 1 })
	if c := got[0].Codex; c == nil || c.FiveHour.UsedPercent != 37 {
		t.Fatalf("codex %+v", got[0].Codex)
	}
	if got[0].Claude != nil {
		t.Fatal("claude without usage.json")
	}
	time.Sleep(100 * time.Millisecond) // unchanged → no more callbacks
	mu.Lock()
	if len(got) != 1 {
		t.Fatalf("callbacks on no change: %d", len(got))
	}
	mu.Unlock()

	b, _ := json.Marshal(protocol.Limits{FiveHour: &protocol.Window{UsedPercent: 55}, UpdatedAt: time.Now()})
	os.WriteFile(usageFile, b, 0o644)
	waitFor(func() bool { return len(got) == 2 })
	if got[1].Claude.FiveHour.UsedPercent != 55 || got[1].Codex == nil {
		t.Fatalf("%+v", got[1])
	}
}

func TestReadTail(t *testing.T) {
	p := filepath.Join(t.TempDir(), "r.jsonl")
	big := strings.Repeat("x", 300*1024)
	os.WriteFile(p, []byte(`{"a":"`+big+`"}`+"\n"+`{"rate_limits":{"primary":{"used_percent":5}}}`+"\n"), 0o644)
	lines, err := readTail(p, 256*1024)
	if err != nil {
		t.Fatal(err)
	}
	l, ok := ParseCodexRollout(lines)
	if !ok || l.FiveHour.UsedPercent != 5 {
		t.Fatalf("%+v %v", l, ok)
	}
}

// A previous command that leaves a background child holding stdout still has
// its output shown, promptly.
func TestRunPreviousBackgroundChild(t *testing.T) {
	start := time.Now()
	out, ok := runPrevious("echo hi; sleep 5 &", nil)
	if el := time.Since(start); el > 2500*time.Millisecond {
		t.Fatalf("took %v", el)
	}
	if !ok || out != "hi\n" {
		t.Fatalf("out=%q ok=%v", out, ok)
	}
}

// Output is capped at 64 KB and a flood returns within the timeout.
func TestRunPreviousCapped(t *testing.T) {
	out, ok := runPrevious("head -c 200000 /dev/zero | tr '\\0' a", nil)
	if !ok || len(out) != maxPreviousOut || strings.Trim(out, "a") != "" {
		t.Fatalf("len=%d ok=%v", len(out), ok)
	}
	start := time.Now()
	out, _ = runPrevious("yes", nil)
	if el := time.Since(start); el > 2500*time.Millisecond {
		t.Fatalf("flood took %v", el)
	}
	if len(out) > maxPreviousOut {
		t.Fatalf("flood output %d bytes", len(out))
	}
}
