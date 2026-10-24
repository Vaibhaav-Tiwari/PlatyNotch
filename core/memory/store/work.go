package store

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ErrChunkGone reports that a chunk no longer exists (purged while a worker
// was processing it).
var ErrChunkGone = errors.New("chunk no longer exists")

func statusCol(kind string) (string, error) {
	switch kind {
	case "embed":
		return "embed_status", nil
	case "extract":
		return "extract_status", nil
	}
	return "", fmt.Errorf("unknown work kind %q", kind)
}

func idArgs(ids []int64) (string, []any) {
	args := make([]any, len(ids))
	for i, id := range ids {
		args[i] = id
	}
	return strings.TrimSuffix(strings.Repeat("?,", len(ids)), ","), args
}

// DueRetryChunk returns the oldest pending chunk for kind that has failed
// before and whose retry is due at now; ok is false when there is none.
func (s *Store) DueRetryChunk(kind string, now time.Time) (c Chunk, ok bool, err error) {
	col, err := statusCol(kind)
	if err != nil {
		return Chunk{}, false, err
	}
	var at int64
	err = s.db.QueryRow(`SELECT c.id,c.version_id,c.thread_id,c.idx,c.text,c.captured_at,c.embed_status,c.extract_status
		FROM chunks c JOIN retry_queue r ON r.kind=? AND r.chunk_id=c.id
		WHERE c.`+col+`='pending' AND r.next_at <= ? ORDER BY r.next_at, c.id LIMIT 1`, kind, ms(now)).
		Scan(&c.ID, &c.VersionID, &c.ThreadID, &c.Idx, &c.Text, &at, &c.EmbedStatus, &c.ExtractStatus)
	if errors.Is(err, sql.ErrNoRows) {
		return Chunk{}, false, nil
	}
	if err != nil {
		return Chunk{}, false, err
	}
	c.CapturedAt = fromMs(at)
	return c, true, nil
}

// ChunksExist reports whether every id still names a chunk.
func (s *Store) ChunksExist(ids []int64) (bool, error) {
	if len(ids) == 0 {
		return true, nil
	}
	ph, args := idArgs(ids)
	var n int
	if err := s.db.QueryRow(`SELECT count(*) FROM chunks WHERE id IN (`+ph+`)`, args...).Scan(&n); err != nil {
		return false, err
	}
	return n == len(ids), nil
}

// DueChunks returns pending chunks for kind whose retry time (if any) is not
// after now, oldest first. A non-empty threadID restricts to that thread.
func (s *Store) DueChunks(kind, threadID string, now time.Time, limit int) ([]Chunk, error) {
	col, err := statusCol(kind)
	if err != nil {
		return nil, err
	}
	q := `SELECT c.id,c.version_id,c.thread_id,c.idx,c.text,c.captured_at,c.embed_status,c.extract_status
		FROM chunks c LEFT JOIN retry_queue r ON r.kind=? AND r.chunk_id=c.id
		WHERE c.` + col + `='pending' AND (r.next_at IS NULL OR r.next_at <= ?)`
	args := []any{kind, ms(now)}
	if threadID != "" {
		q += ` AND c.thread_id=?`
		args = append(args, threadID)
	}
	q += ` ORDER BY c.id LIMIT ?`
	args = append(args, limit)
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Chunk
	for rows.Next() {
		var c Chunk
		var at int64
		if err := rows.Scan(&c.ID, &c.VersionID, &c.ThreadID, &c.Idx, &c.Text, &at, &c.EmbedStatus, &c.ExtractStatus); err != nil {
			return nil, err
		}
		c.CapturedAt = fromMs(at)
		out = append(out, c)
	}
	return out, rows.Err()
}

// QuietExtractThread returns the thread (oldest pending work first) that has
// extract-pending chunks due at now and whose newest chunk was captured at or
// before quietBefore. ok is false when there is none.
func (s *Store) QuietExtractThread(quietBefore, now time.Time) (threadID string, ok bool, err error) {
	err = s.db.QueryRow(`SELECT c.thread_id FROM chunks c
		LEFT JOIN retry_queue r ON r.kind='extract' AND r.chunk_id=c.id
		WHERE c.extract_status='pending' AND (r.next_at IS NULL OR r.next_at <= ?)
		GROUP BY c.thread_id
		HAVING (SELECT max(c2.captured_at) FROM chunks c2 WHERE c2.thread_id=c.thread_id) <= ?
		ORDER BY min(c.id) LIMIT 1`, ms(now), ms(quietBefore)).Scan(&threadID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	return threadID, err == nil, err
}

// SetChunkStatus sets the kind status ("done", "skipped", ...) of the chunks
// and drops their retry rows. Missing chunks are ignored.
func (s *Store) SetChunkStatus(kind string, ids []int64, status string) error {
	col, err := statusCol(kind)
	if err != nil || len(ids) == 0 {
		return err
	}
	ph, args := idArgs(ids)
	tx, err := s.w.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`UPDATE chunks SET `+col+`=? WHERE id IN (`+ph+`)`, append([]any{status}, args...)...); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM retry_queue WHERE kind=? AND chunk_id IN (`+ph+`)`, append([]any{kind}, args...)...); err != nil {
		return err
	}
	return tx.Commit()
}

// FailChunks records a failed attempt for each chunk. next receives the new
// attempt count and returns when to retry; ok=false marks the chunk "failed"
// and removes its retry row. Missing chunks are ignored.
func (s *Store) FailChunks(kind string, ids []int64, lastErr string, next func(attempts int) (at time.Time, ok bool)) error {
	col, err := statusCol(kind)
	if err != nil {
		return err
	}
	tx, err := s.w.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, id := range ids {
		var exists int
		if err := tx.QueryRow(`SELECT count(*) FROM chunks WHERE id=?`, id).Scan(&exists); err != nil {
			return err
		}
		if exists == 0 {
			continue
		}
		var attempts int
		err := tx.QueryRow(`SELECT attempts FROM retry_queue WHERE kind=? AND chunk_id=?`, kind, id).Scan(&attempts)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		attempts++
		at, ok := next(attempts)
		if !ok {
			if _, err := tx.Exec(`UPDATE chunks SET `+col+`='failed' WHERE id=?`, id); err != nil {
				return err
			}
			if _, err := tx.Exec(`DELETE FROM retry_queue WHERE kind=? AND chunk_id=?`, kind, id); err != nil {
				return err
			}
			continue
		}
		if _, err := tx.Exec(`INSERT INTO retry_queue(kind,chunk_id,attempts,next_at,last_error) VALUES(?,?,?,?,?)
			ON CONFLICT(kind,chunk_id) DO UPDATE SET attempts=excluded.attempts, next_at=excluded.next_at, last_error=excluded.last_error`,
			kind, id, attempts, ms(at), lastErr); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ChunkStatus returns a chunk's embed and extract status.
func (s *Store) ChunkStatus(id int64) (embed, extract string, err error) {
	err = s.db.QueryRow(`SELECT embed_status, extract_status FROM chunks WHERE id=?`, id).Scan(&embed, &extract)
	if errors.Is(err, sql.ErrNoRows) {
		err = ErrChunkGone
	}
	return
}

// RetryCount returns the number of rows in the retry queue.
func (s *Store) RetryCount() (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT count(*) FROM retry_queue`).Scan(&n)
	return n, err
}

// GetThread loads a thread by id; ok is false when it does not exist.
func (s *Store) GetThread(id string) (t Thread, ok bool, err error) {
	var c, u int64
	err = s.db.QueryRow(`SELECT id,app_bundle,app_name,key,title,url,created_at,updated_at FROM threads WHERE id=?`, id).
		Scan(&t.ID, &t.AppBundle, &t.AppName, &t.Key, &t.Title, &t.URL, &c, &u)
	if errors.Is(err, sql.ErrNoRows) {
		return Thread{}, false, nil
	}
	if err != nil {
		return Thread{}, false, err
	}
	t.CreatedAt, t.UpdatedAt = fromMs(c), fromMs(u)
	return t, true, nil
}

// ResetSkipped sets every chunk whose kind status is "skipped" (no provider
// was configured when it was processed) back to "pending" and returns how
// many changed.
func (s *Store) ResetSkipped(kind string) (int, error) {
	col, err := statusCol(kind)
	if err != nil {
		return 0, err
	}
	res, err := s.w.Exec(`UPDATE chunks SET ` + col + `='pending' WHERE ` + col + `='skipped'`)
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	return int(n), err
}

// RequeueFailed sets every chunk whose kind status is "failed" (retries
// exhausted, e.g. during a provider outage) back to "pending" with a fresh
// retry budget and returns how many changed.
func (s *Store) RequeueFailed(kind string) (int, error) {
	col, err := statusCol(kind)
	if err != nil {
		return 0, err
	}
	res, err := s.w.Exec(`UPDATE chunks SET ` + col + `='pending' WHERE ` + col + `='failed'`)
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	return int(n), err
}

// RequeueOtherModel marks chunks that are embedded ("done") or gave up
// ("failed") but have no vector from model as pending, so a changed
// embedding model re-embeds everything. It returns how many changed.
func (s *Store) RequeueOtherModel(model string) (int, error) {
	res, err := s.w.Exec(`UPDATE chunks SET embed_status='pending'
		WHERE embed_status IN ('done','failed') AND id NOT IN (SELECT chunk_id FROM chunk_vectors WHERE model=?)`, model)
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	return int(n), err
}
