// Package loops stores, merges, resolves and archives open loops
// (commitments and action items) found by the extraction worker.
package loops

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"time"
	"unicode"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

// TitleHash is the sha256 (hex) of the title lowercased, punctuation
// stripped and whitespace collapsed, so near-identical titles merge.
func TitleHash(title string) string {
	sum := sha256.Sum256([]byte(normTitle(title)))
	return hex.EncodeToString(sum[:])
}

func normTitle(title string) string {
	s := strings.Map(func(r rune) rune {
		if unicode.IsPunct(r) {
			return -1
		}
		return unicode.ToLower(r)
	}, title)
	return strings.Join(strings.Fields(s), " ")
}

// Apply stores r's new loops (merged by TitleHash, sourced to app/thread) and
// resolves still-open loops named in r.Resolutions with their evidence.
func Apply(s *store.Store, r provider.ExtractResult, app, thread string, now time.Time) (changed bool, err error) {
	add := make([]store.Loop, 0, len(r.Loops))
	for _, l := range r.Loops {
		title := strings.Join(strings.Fields(l.Title), " ")
		if normTitle(title) == "" {
			continue
		}
		det := l.DetectedAt
		if det.IsZero() {
			det = now
		}
		add = append(add, store.Loop{
			Title: title, Details: l.Details, Kind: l.Kind, Quote: l.Quote, DueAt: l.DueAt,
			SourceApp: app, SourceThread: thread, DetectedAt: det, TitleHash: TitleHash(title),
		})
	}
	res := make([]store.LoopResolution, 0, len(r.Resolutions))
	for _, x := range r.Resolutions {
		res = append(res, store.LoopResolution{ID: x.LoopID, Evidence: x.Evidence})
	}
	if len(add) == 0 && len(res) == 0 {
		return false, nil
	}
	return s.ApplyLoops(add, res, now)
}

// List returns loops with status ("" = all), newest first.
func List(s *store.Store, status string) ([]protocol.Loop, error) {
	return ListN(s, status, 0)
}

// ListN is List capped at limit rows (limit <= 0 means no cap).
func ListN(s *store.Store, status string, limit int) ([]protocol.Loop, error) {
	rows, err := s.ListLoops(status, limit)
	if err != nil {
		return nil, err
	}
	out := make([]protocol.Loop, len(rows))
	for i, l := range rows {
		out[i] = protocol.Loop{
			ID: l.ID, Title: l.Title, Details: l.Details, Kind: l.Kind, Status: l.Status,
			SourceApp: l.SourceApp, SourceThread: l.SourceThread, Quote: l.Quote,
			DueAt: l.DueAt, DetectedAt: l.DetectedAt, ResolvedAt: l.ResolvedAt, Evidence: l.Evidence,
		}
	}
	return out, nil
}

// validStatus lists the statuses a loop may have.
var validStatus = map[string]bool{"open": true, "resolved": true, "dismissed": true, "stale": true}

// SetStatus changes a loop's status (open, resolved, dismissed, stale).
// Resolving sets resolved_at to now; any other status clears it.
func SetStatus(s *store.Store, st protocol.LoopSetStatus, now time.Time) error {
	if !validStatus[st.Status] {
		return fmt.Errorf("invalid loop status %q", st.Status)
	}
	return s.SetLoopStatus(st.ID, st.Status, st.Evidence, now)
}

// ArchiveStale marks loops open for longer than olderThan as "stale".
func ArchiveStale(s *store.Store, olderThan time.Duration, now time.Time) (int, error) {
	return s.ArchiveLoops(now.Add(-olderThan))
}
