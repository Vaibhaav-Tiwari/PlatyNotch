package store

import (
	"database/sql"
	"errors"
	"time"
)

// ErrLoopNotFound reports an unknown loop id.
var ErrLoopNotFound = errors.New("loop not found")

// Loop is a row of the loops table.
type Loop struct {
	ID, Title, Details, Kind, Status string
	SourceApp, SourceThread, Quote   string
	DueAt, ResolvedAt                *time.Time
	DetectedAt                       time.Time
	Evidence, TitleHash              string
}

// LoopResolution closes an open loop with evidence.
type LoopResolution struct{ ID, Evidence string }

func nullMs(t *time.Time) any {
	if t == nil {
		return nil
	}
	return ms(*t)
}

// ApplyLoops inserts add (new random ids, status "open") merging by
// TitleHash, then resolves open loops in res, in one transaction. A merge into
// an existing open loop only fills a missing due date or details; existing
// loops in any other status are left alone. changed is true when any row was
// inserted or updated.
func (s *Store) ApplyLoops(add []Loop, res []LoopResolution, now time.Time) (changed bool, err error) {
	tx, err := s.db.Begin()
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	for _, l := range add {
		r, err := tx.Exec(`INSERT INTO loops(id,title,details,kind,status,source_app,source_thread,quote,due_at,detected_at,title_hash)
			VALUES(?,?,?,?,'open',?,?,?,?,?,?)
			ON CONFLICT(title_hash) DO UPDATE SET
			  due_at=COALESCE(loops.due_at, excluded.due_at),
			  details=CASE WHEN loops.details='' THEN excluded.details ELSE loops.details END
			WHERE loops.status='open' AND ((loops.due_at IS NULL AND excluded.due_at IS NOT NULL) OR (loops.details='' AND excluded.details<>''))`,
			newID(), l.Title, l.Details, l.Kind, l.SourceApp, l.SourceThread, l.Quote, nullMs(l.DueAt), ms(l.DetectedAt), l.TitleHash)
		if err != nil {
			return false, err
		}
		if n, _ := r.RowsAffected(); n > 0 {
			changed = true
		}
	}
	for _, x := range res {
		r, err := tx.Exec(`UPDATE loops SET status='resolved', resolved_at=?, evidence=? WHERE id=? AND status='open'`, ms(now), x.Evidence, x.ID)
		if err != nil {
			return false, err
		}
		if n, _ := r.RowsAffected(); n > 0 {
			changed = true
		}
	}
	return changed, tx.Commit()
}

// ListLoops returns loops with status ("" = all), newest first; limit <= 0
// means no limit.
func (s *Store) ListLoops(status string, limit int) ([]Loop, error) {
	q := `SELECT id,title,details,kind,status,source_app,source_thread,quote,due_at,detected_at,resolved_at,evidence,title_hash FROM loops`
	var args []any
	if status != "" {
		q += ` WHERE status=?`
		args = append(args, status)
	}
	q += ` ORDER BY detected_at DESC, id`
	if limit > 0 {
		q += ` LIMIT ?`
		args = append(args, limit)
	}
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Loop
	for rows.Next() {
		var l Loop
		var due, res sql.NullInt64
		var det int64
		if err := rows.Scan(&l.ID, &l.Title, &l.Details, &l.Kind, &l.Status, &l.SourceApp, &l.SourceThread, &l.Quote, &due, &det, &res, &l.Evidence, &l.TitleHash); err != nil {
			return nil, err
		}
		l.DetectedAt = fromMs(det)
		if due.Valid {
			t := fromMs(due.Int64)
			l.DueAt = &t
		}
		if res.Valid {
			t := fromMs(res.Int64)
			l.ResolvedAt = &t
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// SetLoopStatus sets status (caller validates it). "resolved" sets
// resolved_at to now; any other status clears it. A non-empty evidence
// replaces the stored one.
func (s *Store) SetLoopStatus(id, status, evidence string, now time.Time) error {
	var resolvedAt any
	if status == "resolved" {
		resolvedAt = ms(now)
	}
	r, err := s.db.Exec(`UPDATE loops SET status=?, resolved_at=?, evidence=CASE WHEN ?<>'' THEN ? ELSE evidence END WHERE id=?`,
		status, resolvedAt, evidence, evidence, id)
	if err != nil {
		return err
	}
	if n, _ := r.RowsAffected(); n == 0 {
		return ErrLoopNotFound
	}
	return nil
}

// ArchiveLoops marks open loops detected before t as "stale".
func (s *Store) ArchiveLoops(before time.Time) (int, error) {
	r, err := s.db.Exec(`UPDATE loops SET status='stale' WHERE status='open' AND detected_at < ?`, ms(before))
	if err != nil {
		return 0, err
	}
	n, err := r.RowsAffected()
	return int(n), err
}
