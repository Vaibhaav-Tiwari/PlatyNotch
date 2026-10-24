package store

import (
	"context"
	"database/sql"
	"strings"
	"time"
)

// versionWhere is Filter over versions alone (the app through a threads
// subquery), so a window scan stays on versions_created.
func (f Filter) versionWhere() (string, []any) {
	var cl []string
	var args []any
	if !f.Since.IsZero() {
		cl = append(cl, "v.created_at >= ?")
		args = append(args, ms(f.Since))
	}
	if !f.Until.IsZero() {
		cl = append(cl, "v.created_at <= ?")
		args = append(args, ms(f.Until))
	}
	if f.App != "" {
		cl = append(cl, "v.thread_id IN (SELECT id FROM threads WHERE LOWER(app_bundle) = LOWER(?) OR LOWER(app_name) = LOWER(?))")
		args = append(args, f.App, f.App)
	}
	if len(cl) == 0 {
		return "", nil
	}
	return " WHERE " + strings.Join(cl, " AND "), args
}

// VersionVisit is one version in a window: a thread active in an hour, at its
// latest capture in that hour.
type VersionVisit struct {
	ThreadID string
	At       time.Time
}

// GraphWindow reads, in one read transaction (one snapshot), the versions
// matching f oldest first (ties by thread id), and their threads, most
// recently updated first (ties by id).
func (s *Store) GraphWindow(f Filter) ([]VersionVisit, []Thread, error) {
	tx, err := s.db.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback()
	w, args := f.versionWhere()
	visits, err := scanVisits(tx.Query(`SELECT v.thread_id, v.created_at FROM versions v`+w+` ORDER BY v.created_at, v.thread_id`, args...))
	if err != nil {
		return nil, nil, err
	}
	threads, err := scanThreads(tx.Query(`SELECT id,app_bundle,app_name,key,title,url,created_at,updated_at FROM threads
		WHERE id IN (SELECT v.thread_id FROM versions v`+w+`) ORDER BY updated_at DESC, id`, args...))
	if err != nil {
		return nil, nil, err
	}
	return visits, threads, tx.Commit()
}

func scanVisits(rows *sql.Rows, err error) ([]VersionVisit, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []VersionVisit
	for rows.Next() {
		var v VersionVisit
		var at int64
		if err := rows.Scan(&v.ThreadID, &at); err != nil {
			return nil, err
		}
		v.At = fromMs(at)
		out = append(out, v)
	}
	return out, rows.Err()
}

func scanThreads(rows *sql.Rows, err error) ([]Thread, error) {
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
