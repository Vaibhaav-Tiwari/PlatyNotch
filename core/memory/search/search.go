// Package search implements hybrid retrieval over local memory: FTS5 bm25
// keyword ranking fused with vector cosine similarity (when an embedder is
// configured) by reciprocal rank fusion.
package search

import (
	"context"
	"math"
	"sort"
	"strings"
	"unicode"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/provider"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/memory/store"
	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/protocol"
)

const (
	defaultLimit = 10
	maxLimit     = 50
	topK         = 50
	vectorWindow = 50000
	rrfK         = 60
	snippetRunes = 300
)

// Cosine returns the cosine similarity of a and b, or 0 when the lengths
// differ or either vector has zero magnitude.
func Cosine(a, b []float32) float32 {
	if len(a) != len(b) || len(a) == 0 {
		return 0
	}
	var dot, na, nb float64
	for i := range a {
		x, y := float64(a[i]), float64(b[i])
		dot += x * y
		na += x * x
		nb += y * y
	}
	if na == 0 || nb == 0 {
		return 0
	}
	return float32(dot / (math.Sqrt(na) * math.Sqrt(nb)))
}

// terms splits a query into searchable tokens (those containing a letter or digit).
func terms(q string) []string {
	var out []string
	for _, w := range strings.Fields(q) {
		if strings.IndexFunc(w, func(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }) >= 0 {
			out = append(out, w)
		}
	}
	return out
}

// matchExpr quotes every token so user punctuation and FTS operators are
// literal; tokens are OR-ed and ranked by bm25.
func matchExpr(ts []string) string {
	qs := make([]string, len(ts))
	for i, w := range ts {
		qs[i] = `"` + strings.ReplaceAll(w, `"`, `""`) + `"`
	}
	return strings.Join(qs, " OR ")
}

// snippet returns up to 300 runes of text centered on the first query term.
func snippet(text, query string) string {
	r := []rune(text)
	if len(r) <= snippetRunes {
		return text
	}
	start := 0
	lower := strings.ToLower(text)
	for _, w := range terms(query) {
		w = strings.ToLower(strings.Trim(w, `"'()?!.,;:*`))
		if w == "" {
			continue
		}
		if bi := strings.Index(lower, w); bi >= 0 {
			// byte index in lowered text; convert via rune count of the prefix of the original
			// (lowering can change byte lengths only for rare runes; clamp afterwards).
			ri := len([]rune(lower[:bi]))
			start = ri - snippetRunes/3
			break
		}
	}
	if start < 0 {
		start = 0
	}
	if start+snippetRunes > len(r) {
		start = len(r) - snippetRunes
	}
	return string(r[start : start+snippetRunes])
}

type cand struct {
	score float64
	row   store.ChunkRow
}

// Search runs a hybrid query. An empty query lists the most recent matches.
func Search(ctx context.Context, s *store.Store, e provider.Embedder, q protocol.MemorySearch) ([]protocol.MemoryHit, error) {
	limit := q.Limit
	if limit <= 0 {
		limit = defaultLimit
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	var f store.Filter
	if q.Since != nil {
		f.Since = *q.Since
	}
	if q.Until != nil {
		f.Until = *q.Until
	}
	f.App = strings.TrimSpace(q.App)

	ts := terms(q.Query)
	if len(ts) == 0 {
		rows, err := s.RecentThreads(f, limit)
		if err != nil {
			return nil, err
		}
		cs := make([]cand, len(rows))
		for i, r := range rows {
			cs[i] = cand{1.0 / float64(rrfK+i+1), r}
		}
		return group(cs, q.Query, limit), nil
	}

	score := map[int64]float64{}
	rowByID := map[int64]store.ChunkRow{}

	kwRows, kwErr := s.SearchFTS(matchExpr(ts), f, topK)
	for i, r := range kwRows {
		score[r.ChunkID] += 1.0 / float64(rrfK+i+1)
		rowByID[r.ChunkID] = r
	}

	if e != nil {
		if err := vectorRank(ctx, s, e, q.Query, f, score); err == nil {
			var missing []int64
			for id := range score {
				if _, ok := rowByID[id]; !ok {
					missing = append(missing, id)
				}
			}
			rows, err := s.ChunksByIDs(missing)
			if err != nil && kwErr == nil {
				kwErr = err // surface only if nothing usable
			}
			for _, r := range rows {
				rowByID[r.ChunkID] = r
			}
		}
		// embedding failure: keyword-only result stands.
	}
	if kwErr != nil && len(score) == 0 {
		return nil, kwErr
	}
	cs := make([]cand, 0, len(score))
	for id, sc := range score {
		if r, ok := rowByID[id]; ok {
			cs = append(cs, cand{sc, r})
		}
	}
	return group(cs, q.Query, limit), nil
}

// vectorRank adds RRF contributions from the top-K cosine matches into score.
func vectorRank(ctx context.Context, s *store.Store, e provider.Embedder, query string, f store.Filter, score map[int64]float64) error {
	vs, err := e.Embed(ctx, []string{query})
	if err != nil {
		return err
	}
	if len(vs) != 1 || len(vs[0]) == 0 {
		return nil
	}
	qv := vs[0]
	type sc struct {
		id int64
		s  float32
	}
	var all []sc
	err = s.VisitVectors(e.Model(), f, vectorWindow, func(id int64, v []float32) {
		if len(v) != len(qv) {
			return
		}
		all = append(all, sc{id, Cosine(qv, v)})
	})
	if err != nil {
		return err
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].s != all[j].s {
			return all[i].s > all[j].s
		}
		return all[i].id > all[j].id
	})
	if len(all) > topK {
		all = all[:topK]
	}
	for i, c := range all {
		score[c.id] += 1.0 / float64(rrfK+i+1)
	}
	return nil
}

// group keeps the best chunk per thread, orders by score then recency, and
// trims to limit.
func group(cs []cand, query string, limit int) []protocol.MemoryHit {
	sort.Slice(cs, func(i, j int) bool {
		if cs[i].score != cs[j].score {
			return cs[i].score > cs[j].score
		}
		if !cs[i].row.CapturedAt.Equal(cs[j].row.CapturedAt) {
			return cs[i].row.CapturedAt.After(cs[j].row.CapturedAt)
		}
		return cs[i].row.ChunkID > cs[j].row.ChunkID
	})
	seen := map[string]bool{}
	out := []protocol.MemoryHit{}
	for _, c := range cs {
		if seen[c.row.ThreadID] {
			continue
		}
		seen[c.row.ThreadID] = true
		app := c.row.AppName
		if app == "" {
			app = c.row.AppBundle
		}
		out = append(out, protocol.MemoryHit{
			ThreadID: c.row.ThreadID, Title: c.row.Title, SourceApp: app,
			Snippet: snippet(c.row.Text, query), Score: c.score, At: c.row.CapturedAt,
		})
		if len(out) == limit {
			break
		}
	}
	return out
}
