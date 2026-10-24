package ingest

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/config"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

const (
	minChars     = 40
	maxChars     = 200_000
	precapSlack  = 4096
	chunkSize    = 1200
	chunkOverlap = 150
)

type Ingester struct {
	store *store.Store
	cfg   config.Memory
	now   func() time.Time
}

func New(s *store.Store, cfg config.Memory, now func() time.Time) *Ingester {
	if now == nil {
		now = time.Now
	}
	return &Ingester{store: s, cfg: cfg, now: now}
}

func (i *Ingester) excluded(bundle string) bool {
	for _, list := range [][]string{config.AlwaysExcludedApps, i.cfg.ExcludeApps} {
		for _, a := range list {
			if strings.EqualFold(a, bundle) {
				return true
			}
		}
	}
	return false
}

// Ingest stores one capture and returns how many new chunks it produced.
// Excluded apps and captures under 40 chars are dropped (0, nil).
func (i *Ingester) Ingest(c protocol.CaptureText) (int, error) {
	if i.excluded(c.AppBundle) {
		return 0, nil
	}
	text := c.Text
	// Bound regex work, redact, and only then truncate, so a secret straddling
	// the cap cannot leave a fragment behind.
	if r := []rune(text); len(r) > maxChars+precapSlack {
		text = string(r[:maxChars+precapSlack])
	}
	text = Redact(text)
	if r := []rune(text); len(r) > maxChars {
		text = string(r[:maxChars])
	}
	if utf8.RuneCountInString(strings.TrimSpace(text)) < minChars {
		return 0, nil
	}

	at := c.CapturedAt
	if at.IsZero() {
		at = i.now()
	}
	th, err := i.store.UpsertThread(store.Thread{
		AppBundle: c.AppBundle, AppName: c.AppName, Key: Redact(ThreadKey(c)),
		Title: Redact(c.WindowTitle), URL: Redact(stripURL(c.URL)),
	})
	if err != nil {
		return 0, err
	}
	sum := sha256.Sum256([]byte(text))
	hash := hex.EncodeToString(sum[:])
	vid := make([]byte, 16)
	if _, err := rand.Read(vid); err != nil {
		return 0, err
	}
	v := store.Version{
		ID: hex.EncodeToString(vid), ThreadID: th.ID, HourBucket: at.Unix() / 3600,
		Content: text, ContentHash: hash, Chars: utf8.RuneCountInString(text), CreatedAt: at,
	}
	// One transaction: the version and its chunks are stored together, and only
	// lines not in the last chunked version are chunked, so a window left open is
	// not chunked (and embedded) again every hour.
	return i.store.SaveCapture(v, func(base string) []string {
		return Chunk(NewText(base, text), chunkSize, chunkOverlap)
	})
}

// stripURL keeps only scheme, host and path: query strings and fragments
// routinely carry tokens, and userinfo carries credentials. Unparseable or
// host-less URLs are dropped.
func stripURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return ""
	}
	return (&url.URL{Scheme: u.Scheme, Host: u.Host, Path: u.Path}).String()
}
