// Package store is the SQLite (modernc, pure Go) store behind PlatyNotch's
// local memory. All timestamps are unix milliseconds. TEXT ids are 128-bit
// random hex strings; chunks.id is an INTEGER rowid shared with chunks_fts.
package store

import (
	"crypto/rand"
	"database/sql"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"net/url"
	"os"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct {
	db   *sql.DB
	path string
}

type Thread struct {
	ID, AppBundle, AppName, Key, Title, URL string
	CreatedAt, UpdatedAt                    time.Time
}

type Version struct {
	ID, ThreadID string
	HourBucket   int64
	Content      string
	ContentHash  string
	Chars        int
	CreatedAt    time.Time
}

type Chunk struct {
	ID                         int64
	VersionID, ThreadID        string
	Idx                        int
	Text                       string
	CapturedAt                 time.Time
	EmbedStatus, ExtractStatus string
}

func ms(t time.Time) int64     { return t.UnixMilli() }
func fromMs(v int64) time.Time { return time.UnixMilli(v) }

func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

// Open opens (creating with mode 0600 if needed) the database at path. When
// readOnly is false it enables WAL and runs migrations.
func Open(path string, readOnly bool) (*Store, error) {
	q := "_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)"
	if !readOnly {
		f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
		if err != nil {
			return nil, err
		}
		f.Close()
		if err := os.Chmod(path, 0o600); err != nil {
			return nil, err
		}
		q += "&_pragma=journal_mode(WAL)"
	} else {
		q = "mode=ro&" + q
	}
	u := url.URL{Scheme: "file", Path: path, RawQuery: q}
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, err
	}
	s := &Store{db: db, path: path}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}
	if !readOnly {
		if err := s.migrate(); err != nil {
			db.Close()
			return nil, err
		}
		s.chmod()
	}
	return s, nil
}

// chmod tightens the WAL/SHM sidecars regardless of umask (best effort).
func (s *Store) chmod() {
	for _, suf := range []string{"", "-wal", "-shm"} {
		_ = os.Chmod(s.path+suf, 0o600)
	}
}

func (s *Store) Close() error {
	s.chmod()
	return s.db.Close()
}

func (s *Store) migrate() error {
	if _, err := s.db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations(id INTEGER PRIMARY KEY)`); err != nil {
		return err
	}
	for i, m := range migrations {
		id := i + 1
		var n int
		if err := s.db.QueryRow(`SELECT count(*) FROM schema_migrations WHERE id=?`, id).Scan(&n); err != nil {
			return err
		}
		if n > 0 {
			continue
		}
		tx, err := s.db.Begin()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(m); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %d: %w", id, err)
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations(id) VALUES (?)`, id); err != nil {
			tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// UpsertThread inserts or updates by (app_bundle, key) and returns the row.
func (s *Store) UpsertThread(t Thread) (Thread, error) {
	now := time.Now()
	_, err := s.db.Exec(`INSERT INTO threads(id,app_bundle,app_name,key,title,url,created_at,updated_at)
		VALUES(?,?,?,?,?,?,?,?)
		ON CONFLICT(app_bundle,key) DO UPDATE SET
		  app_name=excluded.app_name, title=excluded.title, url=excluded.url, updated_at=excluded.updated_at`,
		newID(), t.AppBundle, t.AppName, t.Key, t.Title, t.URL, ms(now), ms(now))
	if err != nil {
		return Thread{}, err
	}
	var out Thread
	var c, u int64
	err = s.db.QueryRow(`SELECT id,app_bundle,app_name,key,title,url,created_at,updated_at FROM threads WHERE app_bundle=? AND key=?`,
		t.AppBundle, t.Key).Scan(&out.ID, &out.AppBundle, &out.AppName, &out.Key, &out.Title, &out.URL, &c, &u)
	out.CreatedAt, out.UpdatedAt = fromMs(c), fromMs(u)
	return out, err
}

// PutVersion stores v for (thread, hour_bucket). If one exists it is replaced
// (its chunks are deleted with it) and returned as prev so the caller can diff.
func (s *Store) PutVersion(v Version) (*Version, error) {
	if v.ID == "" {
		v.ID = newID()
	}
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var prev *Version
	var p Version
	var c int64
	err = tx.QueryRow(`SELECT id,thread_id,hour_bucket,content,content_hash,chars,created_at FROM versions WHERE thread_id=? AND hour_bucket=?`,
		v.ThreadID, v.HourBucket).Scan(&p.ID, &p.ThreadID, &p.HourBucket, &p.Content, &p.ContentHash, &p.Chars, &c)
	switch {
	case err == nil:
		p.CreatedAt = fromMs(c)
		prev = &p
		if _, err := tx.Exec(`DELETE FROM versions WHERE id=?`, p.ID); err != nil {
			return nil, err
		}
	case errors.Is(err, sql.ErrNoRows):
	default:
		return nil, err
	}
	if _, err := tx.Exec(`INSERT INTO versions(id,thread_id,hour_bucket,content,content_hash,chars,created_at) VALUES(?,?,?,?,?,?,?)`,
		v.ID, v.ThreadID, v.HourBucket, v.Content, v.ContentHash, v.Chars, ms(v.CreatedAt)); err != nil {
		return nil, err
	}
	return prev, tx.Commit()
}

// AddChunks inserts chunks (status pending) and returns their ids.
func (s *Store) AddChunks(cs []Chunk) ([]int64, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	ids := make([]int64, 0, len(cs))
	for _, c := range cs {
		r, err := tx.Exec(`INSERT INTO chunks(version_id,thread_id,idx,text,captured_at) VALUES(?,?,?,?,?)`,
			c.VersionID, c.ThreadID, c.Idx, c.Text, ms(c.CapturedAt))
		if err != nil {
			return nil, err
		}
		id, err := r.LastInsertId()
		if err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, tx.Commit()
}

// SetVector stores the embedding (little-endian float32) and marks the chunk embedded.
func (s *Store) SetVector(chunkID int64, model string, vec []float32) error {
	b := make([]byte, 4*len(vec))
	for i, f := range vec {
		binary.LittleEndian.PutUint32(b[4*i:], math.Float32bits(f))
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`INSERT OR REPLACE INTO chunk_vectors(chunk_id,model,dim,vec) VALUES(?,?,?,?)`, chunkID, model, len(vec), b); err != nil {
		return err
	}
	if _, err := tx.Exec(`UPDATE chunks SET embed_status='done' WHERE id=?`, chunkID); err != nil {
		return err
	}
	return tx.Commit()
}

// PendingChunks returns chunks awaiting kind ("embed" or "extract"), oldest first.
func (s *Store) PendingChunks(kind string, limit int) ([]Chunk, error) {
	var col string
	switch kind {
	case "embed":
		col = "embed_status"
	case "extract":
		col = "extract_status"
	default:
		return nil, fmt.Errorf("unknown pending kind %q", kind)
	}
	rows, err := s.db.Query(`SELECT id,version_id,thread_id,idx,text,captured_at,embed_status,extract_status FROM chunks WHERE `+col+`='pending' ORDER BY id LIMIT ?`, limit)
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

// Counts reports row counts; pending is chunks still awaiting embed or extract.
func (s *Store) Counts() (threads, versions, chunks, pending int, err error) {
	err = s.db.QueryRow(`SELECT
		(SELECT count(*) FROM threads),(SELECT count(*) FROM versions),(SELECT count(*) FROM chunks),
		(SELECT count(*) FROM chunks WHERE embed_status='pending' OR extract_status='pending')`).
		Scan(&threads, &versions, &chunks, &pending)
	return
}

// PurgeBefore deletes chunks captured and versions created before t (FTS rows
// and vectors go with them), then threads left with no versions. It returns
// the number of chunks deleted.
func (s *Store) PurgeBefore(t time.Time) (int, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	r, err := tx.Exec(`DELETE FROM chunks WHERE captured_at < ?`, ms(t))
	if err != nil {
		return 0, err
	}
	n, _ := r.RowsAffected()
	if _, err := tx.Exec(`DELETE FROM versions WHERE created_at < ?`, ms(t)); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(`DELETE FROM threads WHERE id NOT IN (SELECT thread_id FROM versions)`); err != nil {
		return 0, err
	}
	return int(n), tx.Commit()
}
