package store

import (
	"database/sql"
	"encoding/binary"
	"errors"
	"math"
	"strings"
	"time"
)

// Filter restricts read queries. Zero Since/Until mean unbounded; App matches
// threads.app_bundle or threads.app_name case-insensitively.
type Filter struct {
	Since, Until time.Time
	App          string
}

// ChunkRow is a chunk joined with its thread, for search results.
type ChunkRow struct {
	ChunkID    int64
	ThreadID   string
	Title      string
	AppBundle  string
	AppName    string
	Text       string
	CapturedAt time.Time
}

const chunkCols = `c.id, c.thread_id, t.title, t.app_bundle, t.app_name, c.text, c.captured_at`

func (f Filter) where() (string, []any) {
	var cl []string
	var args []any
	if !f.Since.IsZero() {
		cl = append(cl, "c.captured_at >= ?")
		args = append(args, ms(f.Since))
	}
	if !f.Until.IsZero() {
		cl = append(cl, "c.captured_at <= ?")
		args = append(args, ms(f.Until))
	}
	if f.App != "" {
		cl = append(cl, "(LOWER(t.app_bundle) = LOWER(?) OR LOWER(t.app_name) = LOWER(?))")
		args = append(args, f.App, f.App)
	}
	if len(cl) == 0 {
		return "", nil
	}
	return " AND " + strings.Join(cl, " AND "), args
}

func (s *Store) scanRows(q string, args ...any) ([]ChunkRow, error) {
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ChunkRow
	for rows.Next() {
		var r ChunkRow
		var at int64
		if err := rows.Scan(&r.ChunkID, &r.ThreadID, &r.Title, &r.AppBundle, &r.AppName, &r.Text, &at); err != nil {
			return nil, err
		}
		r.CapturedAt = fromMs(at)
		out = append(out, r)
	}
	return out, rows.Err()
}

// SearchFTS runs an FTS5 MATCH expression (caller must make it syntactically
// safe) and returns up to limit rows ordered best bm25 first.
func (s *Store) SearchFTS(match string, f Filter, limit int) ([]ChunkRow, error) {
	w, wargs := f.where()
	args := append([]any{match}, wargs...)
	args = append(args, limit)
	return s.scanRows(`SELECT `+chunkCols+` FROM chunks_fts
		JOIN chunks c ON c.id = chunks_fts.rowid JOIN threads t ON t.id = c.thread_id
		WHERE chunks_fts MATCH ?`+w+` ORDER BY bm25(chunks_fts) LIMIT ?`, args...)
}

// RecentThreads returns one chunk per thread for the limit threads captured
// most recently (matching f): the first chunk of each thread's newest capture.
// Listing recent chunks instead let one busy thread fill the whole list.
func (s *Store) RecentThreads(f Filter, limit int) ([]ChunkRow, error) {
	w, args := f.where()
	args = append(args, limit)
	return s.scanRows(`SELECT id, thread_id, title, app_bundle, app_name, text, captured_at FROM (
		SELECT `+chunkCols+`, ROW_NUMBER() OVER (PARTITION BY c.thread_id ORDER BY c.captured_at DESC, c.id) AS rn
		FROM chunks c JOIN threads t ON t.id = c.thread_id WHERE 1=1`+w+`)
		WHERE rn = 1 ORDER BY captured_at DESC, id DESC LIMIT ?`, args...)
}

// LatestVersionBefore returns the thread's newest version from an earlier hour
// than hourBucket, or nil.
func (s *Store) LatestVersionBefore(threadID string, hourBucket int64) (*Version, error) {
	var v Version
	var c int64
	err := s.db.QueryRow(`SELECT id,thread_id,hour_bucket,content,content_hash,chars,created_at FROM versions
		WHERE thread_id=? AND hour_bucket<? ORDER BY hour_bucket DESC LIMIT 1`, threadID, hourBucket).
		Scan(&v.ID, &v.ThreadID, &v.HourBucket, &v.Content, &v.ContentHash, &v.Chars, &c)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	v.CreatedAt = fromMs(c)
	return &v, nil
}

// ChunksByIDs loads chunk rows for the given ids (any order).
func (s *Store) ChunksByIDs(ids []int64) ([]ChunkRow, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	ph := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	return s.scanRows(`SELECT `+chunkCols+` FROM chunks c JOIN threads t ON t.id = c.thread_id
		WHERE c.id IN (`+ph+`)`, args...)
}

// VisitVectors streams the vectors of the given model belonging to the limit
// most recent chunks matching f, calling fn for each (the slice is reused only
// if fn retains nothing; here it is freshly allocated per row).
func (s *Store) VisitVectors(model string, f Filter, limit int, fn func(chunkID int64, vec []float32)) error {
	w, wargs := f.where()
	args := append([]any{model}, wargs...)
	args = append(args, limit)
	rows, err := s.db.Query(`SELECT v.chunk_id, v.dim, v.vec FROM chunk_vectors v
		JOIN chunks c ON c.id = v.chunk_id JOIN threads t ON t.id = c.thread_id
		WHERE v.model = ?`+w+` ORDER BY c.captured_at DESC, c.id DESC LIMIT ?`, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id int64
		var dim int
		var b []byte
		if err := rows.Scan(&id, &dim, &b); err != nil {
			return err
		}
		if dim <= 0 || len(b) != 4*dim {
			continue
		}
		v := make([]float32, dim)
		for i := range v {
			v[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[4*i:]))
		}
		fn(id, v)
	}
	return rows.Err()
}

// ThreadVersions returns the thread's versions created at or after since,
// oldest first.
func (s *Store) ThreadVersions(threadID string, since time.Time) ([]Version, error) {
	rows, err := s.db.Query(`SELECT id,thread_id,hour_bucket,content,content_hash,chars,created_at
		FROM versions WHERE thread_id=? AND created_at>=? ORDER BY created_at, hour_bucket`, threadID, ms(since))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Version
	for rows.Next() {
		var v Version
		var c int64
		if err := rows.Scan(&v.ID, &v.ThreadID, &v.HourBucket, &v.Content, &v.ContentHash, &v.Chars, &c); err != nil {
			return nil, err
		}
		v.CreatedAt = fromMs(c)
		out = append(out, v)
	}
	return out, rows.Err()
}

// ThreadsUpdatedSince returns threads updated at or after since, newest first.
func (s *Store) ThreadsUpdatedSince(since time.Time, limit int) ([]Thread, error) {
	rows, err := s.db.Query(`SELECT id,app_bundle,app_name,key,title,url,created_at,updated_at
		FROM threads WHERE updated_at>=? ORDER BY updated_at DESC LIMIT ?`, ms(since), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Thread
	for rows.Next() {
		var t Thread
		var c, u int64
		if err := rows.Scan(&t.ID, &t.AppBundle, &t.AppName, &t.Key, &t.Title, &t.URL, &c, &u); err != nil {
			return nil, err
		}
		t.CreatedAt, t.UpdatedAt = fromMs(c), fromMs(u)
		out = append(out, t)
	}
	return out, rows.Err()
}
