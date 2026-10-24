package store

import "strings"

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

// VisitVersionTimes calls fn with the thread id of every version matching f
// (one per thread and active hour), oldest first, ties by thread id. A
// version's time is its hour's latest capture, so consecutive calls for
// different threads are window switches.
func (s *Store) VisitVersionTimes(f Filter, fn func(threadID string)) error {
	w, args := f.versionWhere()
	rows, err := s.db.Query(`SELECT v.thread_id FROM versions v`+w+` ORDER BY v.created_at, v.thread_id`, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	var id string
	for rows.Next() {
		if err := rows.Scan(&id); err != nil {
			return err
		}
		fn(id)
	}
	return rows.Err()
}

// ThreadsWithVersions returns the threads that have a version matching f, in
// no particular order.
func (s *Store) ThreadsWithVersions(f Filter) ([]Thread, error) {
	w, args := f.versionWhere()
	rows, err := s.db.Query(`SELECT id,app_bundle,app_name,key,title,url,created_at,updated_at FROM threads
		WHERE id IN (SELECT v.thread_id FROM versions v`+w+`)`, args...)
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
