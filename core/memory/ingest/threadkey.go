// Package ingest turns captured on-screen text into threads, hourly versions
// and searchable chunks, redacting secrets before anything is stored.
package ingest

import (
	"net/url"
	"regexp"
	"strings"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

var counterPrefix = regexp.MustCompile(`^(?:\(\d+\)\s*|[•·]\s*)+`)

// ThreadKey identifies the conversation/page a capture belongs to: URL host+path
// (no query or fragment), else the window title minus unread counters, else the app name.
func ThreadKey(c protocol.CaptureText) string {
	if c.URL != "" {
		if u, err := url.Parse(c.URL); err == nil && u.Host != "" {
			return u.Host + u.Path
		}
	}
	if t := strings.TrimSpace(counterPrefix.ReplaceAllString(strings.TrimSpace(c.WindowTitle), "")); t != "" {
		return t
	}
	return c.AppName
}
