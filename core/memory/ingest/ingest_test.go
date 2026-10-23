package ingest

import (
	"fmt"
	"math/rand"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

func TestThreadKeyURL(t *testing.T) {
	c := protocol.CaptureText{AppName: "Chrome", WindowTitle: "Inbox", URL: "https://mail.google.com/mail/u/0/#inbox/abc?x=1"}
	if got := ThreadKey(c); got != "mail.google.com/mail/u/0" {
		t.Fatalf("got %q", got)
	}
	for _, u := range []string{"https://Example.com/a/", "https://example.com/a"} {
		c.URL = u
		if got := ThreadKey(c); got != "example.com/a" {
			t.Fatalf("%s: got %q", u, got)
		}
	}
	c.URL = "https://Example.com"
	if got := ThreadKey(c); got != "example.com/" {
		t.Fatalf("got %q", got)
	}
	c.URL = "https://example.com/a/b?q=1"
	if got := ThreadKey(c); got != "example.com/a/b" {
		t.Fatalf("got %q", got)
	}
}

func TestThreadKeyStripsCounters(t *testing.T) {
	for in, want := range map[string]string{
		"(3) Slack - general": "Slack - general",
		"• Notes":             "Notes",
		"(12) (3) Foo":        "Foo",
	} {
		if got := ThreadKey(protocol.CaptureText{AppName: "App", WindowTitle: in}); got != want {
			t.Errorf("%q: got %q want %q", in, got, want)
		}
	}
	if got := ThreadKey(protocol.CaptureText{AppName: "Terminal"}); got != "Terminal" {
		t.Fatalf("got %q", got)
	}
}

func TestRedact(t *testing.T) {
	cases := map[string]string{
		"card 4242 4242 4242 4242 end":                                                    "card [redacted] end",
		"card 4242-4242-4242-4242 end":                                                    "card [redacted] end",
		"card 4242424242424242 end":                                                       "card [redacted] end",
		"key sk-abcdefghijklmnopqrstuvwx1234 ok":                                          "key [redacted] ok",
		"aws AKIAIOSFODNN7EXAMPLE ok":                                                     "aws [redacted] ok",
		"jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc_DEF-123 ok":                         "jwt [redacted] ok",
		"a\n-----BEGIN RSA PRIVATE KEY-----\nMIIE\nabc\n-----END RSA PRIVATE KEY-----\nb": "a\n[redacted]\nb",
		"-----BEGIN PRIVATE KEY-----\ntruncated":                                          "[redacted]",
	}
	for in, want := range cases {
		if got := Redact(in); got != want {
			t.Errorf("Redact(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{
		"on 2024-01-15 4242 4242 4242 4242 paid": "on 2024-01-15 [redacted] paid",
		"order 123 4242424242424242":             "order 123 [redacted]",
		"x 1398 8333 3494 9149 9432 0603 y":      "x [redacted] y",
		"4242 4242 4242 4242 12/27":              "[redacted] 12/27",
	} {
		if got := Redact(in); got != want {
			t.Errorf("Redact(%q) = %q, want %q", in, got, want)
		}
	}
	for _, keep := range []string{"num 1234567890123456 x", "short sk-abc", "phone 555-1234", "id 12345678901234567890123"} {
		if got := Redact(keep); got != keep {
			t.Errorf("Redact(%q) changed to %q", keep, got)
		}
	}
}

func TestNewText(t *testing.T) {
	prev := "a\nb\nc"
	cur := "a\nx\nb\ny\n\nz"
	if got := NewText(prev, cur); got != "x\ny\n\nz" {
		t.Fatalf("got %q", got)
	}
	if got := NewText("", "a\nb"); got != "a\nb" {
		t.Fatalf("got %q", got)
	}
	if got := NewText("a\nb", "b\na"); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestChunkSizes(t *testing.T) {
	var b strings.Builder
	for b.Len() < 5000 {
		b.WriteString("word ünï ")
	}
	s := b.String()[:5000]
	cs := Chunk(s, 1200, 150)
	if len(cs) < 4 {
		t.Fatalf("only %d chunks", len(cs))
	}
	for i, c := range cs {
		if n := utf8.RuneCountInString(c); n > 1200 || n == 0 {
			t.Fatalf("chunk %d has %d runes", i, n)
		}
		if i > 0 {
			ov := 0
			for k := 1; k <= len(cs[i-1]) && k <= len(c); k++ {
				if strings.HasSuffix(cs[i-1], c[:k]) {
					ov = k
				}
			}
			if ov < 100 {
				t.Fatalf("overlap %d between %d and %d", ov, i-1, i)
			}
		}
	}
	// no-space text hard cuts
	for _, c := range Chunk(strings.Repeat("x", 3000), 1200, 150) {
		if utf8.RuneCountInString(c) > 1200 {
			t.Fatal("hard cut too big")
		}
	}
	if got := Chunk("short", 1200, 150); len(got) != 1 || got[0] != "short" {
		t.Fatalf("got %v", got)
	}
	if got := Chunk("  ", 1200, 150); len(got) != 0 {
		t.Fatalf("got %v", got)
	}
}

func TestChunkPrefersParagraph(t *testing.T) {
	p1 := strings.Repeat("a", 800)
	p2 := strings.Repeat("b", 800)
	cs := Chunk(p1+"\n\n"+p2, 1200, 150)
	if !strings.HasSuffix(cs[0], "\n\n") && strings.Contains(cs[0], "b") && !strings.HasSuffix(strings.TrimRight(cs[0], "\n"), "a") {
		t.Fatalf("did not break on paragraph: %q...", cs[0][len(cs[0])-5:])
	}
}

func newIngester(t *testing.T, now *time.Time) (*Ingester, *store.Store) {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "m.db"), false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	cfg := config.Memory{ExcludeApps: []string{"com.secret"}}
	return New(s, cfg, func() time.Time { return *now }), s
}

func capture(text string) protocol.CaptureText {
	return protocol.CaptureText{AppBundle: "com.app", AppName: "App", WindowTitle: "Win", Text: text}
}

var long = strings.Repeat("The quick brown fox jumps over the lazy dog. ", 4)

func TestExcludedAppDropped(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	c := capture(long)
	c.AppBundle = "com.secret"
	n, err := i.Ingest(c)
	if err != nil || n != 0 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if th, v, ch, _, _ := s.Counts(); th+v+ch != 0 {
		t.Fatal("stored something")
	}
}

func TestShortCaptureDropped(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	n, err := i.Ingest(capture("too short"))
	if err != nil || n != 0 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if th, _, _, _, _ := s.Counts(); th != 0 {
		t.Fatal("stored thread")
	}
}

func TestRedactedBeforeStorage(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	if _, err := i.Ingest(capture(long + "\nexport KEY=sk-abcdefghijklmnopqrstuvwx1234")); err != nil {
		t.Fatal(err)
	}
	ps, _ := s.PendingChunks("embed", 10)
	if len(ps) == 0 {
		t.Fatal("no chunks")
	}
	for _, c := range ps {
		if strings.Contains(c.Text, "sk-abc") {
			t.Fatal("secret in chunk")
		}
	}
}

func TestRepeatedCaptureNoDuplicateChunks(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	first := 0
	for k := 0; k < 10; k++ {
		now = now.Add(20 * time.Second)
		n, err := i.Ingest(capture(long))
		if err != nil {
			t.Fatal(err)
		}
		if k == 0 {
			first = n
		} else if n != 0 {
			t.Fatalf("repeat %d added %d chunks", k, n)
		}
	}
	if first == 0 {
		t.Fatal("first capture added nothing")
	}
	th, v, ch, _, _ := s.Counts()
	if th != 1 || v != 1 || ch != first {
		t.Fatalf("threads=%d versions=%d chunks=%d first=%d", th, v, ch, first)
	}
}

func TestChangedTextAddsOnlyNewChunksSameVersion(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	if _, err := i.Ingest(capture(long)); err != nil {
		t.Fatal(err)
	}
	n, err := i.Ingest(capture(long + "\nA brand new line appears here, long enough to matter."))
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	_, v, ch, _, _ := s.Counts()
	if v != 1 || ch != 2 {
		t.Fatalf("versions=%d chunks=%d", v, ch)
	}
	ps, _ := s.PendingChunks("embed", 10)
	idx := map[int]bool{}
	for _, c := range ps {
		idx[c.Idx] = true
	}
	if len(idx) != 2 {
		t.Fatalf("idx not distinct: %v", idx)
	}
}

func TestNewHourNewVersion(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	if _, err := i.Ingest(capture(long)); err != nil {
		t.Fatal(err)
	}
	now = now.Add(time.Hour)
	n, err := i.Ingest(capture(long))
	if err != nil || n == 0 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	th, v, _, _, _ := s.Counts()
	if th != 1 || v != 2 {
		t.Fatalf("threads=%d versions=%d", th, v)
	}
}

func TestSecretStraddlingCapIsRedacted(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	key := "sk-abcdefghijklmnopqrstuvwxyz0123456789"
	text := strings.Repeat("a", maxChars-10) + key + " tail"
	if _, err := i.Ingest(capture(text)); err != nil {
		t.Fatal(err)
	}
	ps, _ := s.PendingChunks("embed", 1000)
	for _, c := range ps {
		if strings.Contains(c.Text, "sk-") {
			t.Fatal("key fragment stored")
		}
	}
}

func TestMinimumMeasuredAfterRedaction(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	n, err := i.Ingest(capture("sk-abcdefghijklmnopqrstuvwxyz0123456789 ok"))
	if err != nil || n != 0 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	if th, _, _, _, _ := s.Counts(); th != 0 {
		t.Fatal("stored")
	}
}

func TestHourBucketFollowsCapturedAt(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	i, s := newIngester(t, &now)
	c := capture(long)
	c.CapturedAt = now.Add(-5 * time.Hour)
	if _, err := i.Ingest(c); err != nil {
		t.Fatal(err)
	}
	c.CapturedAt = now // same now, different bucket than first
	if _, err := i.Ingest(c); err != nil {
		t.Fatal(err)
	}
	if _, v, _, _, _ := s.Counts(); v != 2 {
		t.Fatalf("versions=%d", v)
	}
}

func TestRedactCardNeverLeaks(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	group := func() string { return fmt.Sprintf("%04d", rng.Intn(10000)) }
	for n := 0; n < 2000; n++ {
		var d []int
		for k := 0; k < 15; k++ {
			d = append(d, rng.Intn(10))
		}
		for c := 0; c < 10; c++ { // append check digit
			if luhn(append(append([]int{}, d...), c)) {
				d = append(d, c)
				break
			}
		}
		var card strings.Builder
		for k, x := range d {
			if k > 0 && k%4 == 0 {
				card.WriteByte(' ')
			}
			card.WriteByte(byte('0' + x))
		}
		var parts []string
		for k := rng.Intn(3); k > 0; k-- {
			parts = append(parts, group())
		}
		parts = append(parts, card.String())
		if rng.Intn(2) == 0 {
			parts = append(parts, group())
		}
		in := "x " + strings.Join(parts, " ") + " y"
		out := Redact(in)
		for _, g := range strings.Fields(card.String()) {
			if strings.Contains(out, g) {
				t.Fatalf("leak: %q -> %q", in, out)
			}
		}
	}
}
