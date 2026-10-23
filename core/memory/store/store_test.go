package store

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func open(t *testing.T) (*Store, string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "mem.db")
	s, err := Open(p, false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, p
}

func seed(t *testing.T, s *Store, text string, at time.Time) (Thread, []int64) {
	t.Helper()
	th, err := s.UpsertThread(Thread{AppBundle: "com.apple.mail", AppName: "Mail", Key: "k1", Title: "Inbox"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.PutVersion(Version{ID: "v1", ThreadID: th.ID, HourBucket: at.Unix() / 3600, Content: text, ContentHash: "h", Chars: len(text), CreatedAt: at}); err != nil {
		t.Fatal(err)
	}
	ids, err := s.AddChunks([]Chunk{{VersionID: "v1", ThreadID: th.ID, Idx: 0, Text: text, CapturedAt: at}})
	if err != nil {
		t.Fatal(err)
	}
	return th, ids
}

func TestMigrateTwiceIsNoop(t *testing.T) {
	s, p := open(t)
	s.Close()
	s2, err := Open(p, false)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	var n int
	if err := s2.db.QueryRow(`SELECT count(*) FROM schema_migrations`).Scan(&n); err != nil || n != len(migrations) {
		t.Fatalf("migrations=%d err=%v", n, err)
	}
}

func TestPutVersionSameHourReplaces(t *testing.T) {
	s, _ := open(t)
	th, _ := s.UpsertThread(Thread{AppBundle: "a", Key: "k"})
	th2, _ := s.UpsertThread(Thread{AppBundle: "a", Key: "k", Title: "new"})
	if th2.ID != th.ID || th2.Title != "new" {
		t.Fatalf("upsert not idempotent: %+v %+v", th, th2)
	}
	now := time.Now()
	prev, err := s.PutVersion(Version{ID: "a", ThreadID: th.ID, HourBucket: 5, Content: "one", CreatedAt: now})
	if err != nil || prev != nil {
		t.Fatalf("first: %v %v", prev, err)
	}
	prev, err = s.PutVersion(Version{ID: "b", ThreadID: th.ID, HourBucket: 5, Content: "two", CreatedAt: now})
	if err != nil || prev == nil || prev.Content != "one" {
		t.Fatalf("second: %+v %v", prev, err)
	}
	var n int
	var c string
	s.db.QueryRow(`SELECT count(*), max(content) FROM versions`).Scan(&n, &c)
	if n != 1 || c != "two" {
		t.Fatalf("n=%d c=%s", n, c)
	}
}

func TestFTSFindsChunk(t *testing.T) {
	s, _ := open(t)
	_, ids := seed(t, s, "budget email from Priya", time.Now())
	var id int64
	if err := s.db.QueryRow(`SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH 'priya'`).Scan(&id); err != nil || id != ids[0] {
		t.Fatalf("id=%d want %d err=%v", id, ids[0], err)
	}
}

func TestDeleteCascadesFTS(t *testing.T) {
	s, _ := open(t)
	old := time.Now().Add(-48 * time.Hour)
	seed(t, s, "budget email from Priya", old)
	if err := s.SetVector(1, "m", []float32{1, 2}); err != nil {
		t.Fatal(err)
	}
	n, err := s.PurgeBefore(time.Now().Add(-24 * time.Hour))
	if err != nil || n != 1 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	var c int
	s.db.QueryRow(`SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH 'priya'`).Scan(&c)
	if c != 0 {
		t.Fatalf("fts rows remain: %d", c)
	}
	th, v, ch, _, _ := s.Counts()
	var vec int
	s.db.QueryRow(`SELECT count(*) FROM chunk_vectors`).Scan(&vec)
	if v != 0 || ch != 0 || vec != 0 || th != 0 {
		t.Fatalf("remaining th=%d v=%d ch=%d vec=%d", th, v, ch, vec)
	}
}

func TestPendingAndVectors(t *testing.T) {
	s, _ := open(t)
	_, ids := seed(t, s, "hello world", time.Now())
	p, err := s.PendingChunks("embed", 10)
	if err != nil || len(p) != 1 || p[0].EmbedStatus != "pending" {
		t.Fatalf("%+v %v", p, err)
	}
	if err := s.SetVector(ids[0], "m", []float32{0.5, 1.5}); err != nil {
		t.Fatal(err)
	}
	p, _ = s.PendingChunks("embed", 10)
	if len(p) != 0 {
		t.Fatalf("still pending: %+v", p)
	}
	p, _ = s.PendingChunks("extract", 10)
	if len(p) != 1 {
		t.Fatalf("extract pending: %+v", p)
	}
	if _, err := s.PendingChunks("bogus", 1); err == nil {
		t.Fatal("expected error for bad kind")
	}
	_, _, _, pend, _ := s.Counts()
	if pend != 1 {
		t.Fatalf("pending=%d", pend)
	}
}

func TestReadOnlyRejectsWrites(t *testing.T) {
	s, p := open(t)
	seed(t, s, "x", time.Now())
	ro, err := Open(p, true)
	if err != nil {
		t.Fatal(err)
	}
	defer ro.Close()
	if _, err := ro.UpsertThread(Thread{AppBundle: "b", Key: "z"}); err == nil {
		t.Fatal("write succeeded on read-only store")
	}
	if th, _, _, _, err := ro.Counts(); err != nil || th != 1 {
		t.Fatalf("read failed: %d %v", th, err)
	}
}

func TestFileMode0600(t *testing.T) {
	s, p := open(t)
	seed(t, s, "x", time.Now())
	for _, f := range []string{p, p + "-wal", p + "-shm"} {
		fi, err := os.Stat(f)
		if err != nil {
			continue
		}
		if fi.Mode().Perm() != 0o600 {
			t.Errorf("%s mode %v", f, fi.Mode().Perm())
		}
	}
	fi, err := os.Stat(p)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("main file: %v %v", fi, err)
	}
}

func TestPutVersionKeepsChunksAndID(t *testing.T) {
	s, _ := open(t)
	th, _ := s.UpsertThread(Thread{AppBundle: "a", Key: "k"})
	now := time.Now()
	if _, err := s.PutVersion(Version{ID: "orig", ThreadID: th.ID, HourBucket: 7, Content: "alpha", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddChunks([]Chunk{{VersionID: "orig", ThreadID: th.ID, Text: "alpha zebra", CapturedAt: now}}); err != nil {
		t.Fatal(err)
	}
	prev, err := s.PutVersion(Version{ID: "other", ThreadID: th.ID, HourBucket: 7, Content: "alpha beta", Chars: 10})
	if err != nil || prev == nil || prev.ID != "orig" || prev.Content != "alpha" {
		t.Fatalf("prev=%+v err=%v", prev, err)
	}
	var id, content string
	var created int64
	s.db.QueryRow(`SELECT id, content, created_at FROM versions`).Scan(&id, &content, &created)
	if id != "orig" || content != "alpha beta" || created == 0 {
		t.Fatalf("id=%s content=%s created=%d", id, content, created)
	}
	_, _, ch, _, _ := s.Counts()
	var fts int
	s.db.QueryRow(`SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH 'zebra'`).Scan(&fts)
	if ch != 1 || fts != 1 {
		t.Fatalf("chunks=%d fts=%d", ch, fts)
	}
}

func TestPathWithSpace(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Application Support", "Platy Notch")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "mem.db")
	s, err := Open(p, false)
	if err != nil {
		t.Fatal(err)
	}
	seed(t, s, "hello", time.Now())
	ro, err := Open(p, true)
	if err != nil {
		t.Fatal(err)
	}
	defer ro.Close()
	if th, _, _, _, err := ro.Counts(); err != nil || th != 1 {
		t.Fatalf("th=%d err=%v", th, err)
	}
	s.Close()
}

func TestPurgeRetryQueueAndCascadeCount(t *testing.T) {
	s, _ := open(t)
	old := time.Now().Add(-48 * time.Hour)
	th, ids := seed(t, s, "old one", old)
	// chunk captured recently but attached to an old version: cascade-deleted.
	if _, err := s.AddChunks([]Chunk{{VersionID: "v1", ThreadID: th.ID, Idx: 1, Text: "recent", CapturedAt: time.Now()}}); err != nil {
		t.Fatal(err)
	}
	s.db.Exec(`INSERT INTO retry_queue(kind,chunk_id,next_at) VALUES('embed',?,0)`, ids[0])
	s.db.Exec(`INSERT INTO retry_queue(kind,chunk_id,next_at) VALUES('embed',?,0)`, ids[0]+1)
	n, err := s.PurgeBefore(time.Now().Add(-24 * time.Hour))
	if err != nil || n != 2 {
		t.Fatalf("n=%d err=%v", n, err)
	}
	var q int
	s.db.QueryRow(`SELECT count(*) FROM retry_queue`).Scan(&q)
	if q != 0 {
		t.Fatalf("retry rows=%d", q)
	}
	var sd int
	s.db.QueryRow(`PRAGMA secure_delete`).Scan(&sd)
	if sd != 1 {
		t.Fatalf("secure_delete=%d", sd)
	}
}

func TestResetSkipped(t *testing.T) {
	s, _ := open(t)
	_, ids := seed(t, s, "some text", time.Now())
	if err := s.SetChunkStatus("embed", ids, "skipped"); err != nil {
		t.Fatal(err)
	}
	if err := s.SetChunkStatus("extract", ids, "skipped"); err != nil {
		t.Fatal(err)
	}
	n, err := s.ResetSkipped("embed")
	if err != nil || n != 1 {
		t.Fatalf("ResetSkipped(embed) = %d, %v", n, err)
	}
	if e, x, _ := s.ChunkStatus(ids[0]); e != "pending" || x != "skipped" {
		t.Fatalf("after embed reset: embed=%q extract=%q", e, x)
	}
	if n, err := s.ResetSkipped("extract"); err != nil || n != 1 {
		t.Fatalf("ResetSkipped(extract) = %d, %v", n, err)
	}
	if e, x, _ := s.ChunkStatus(ids[0]); e != "pending" || x != "pending" {
		t.Fatalf("after extract reset: embed=%q extract=%q", e, x)
	}
	// done/failed chunks are left alone; unknown kinds are errors.
	if err := s.SetChunkStatus("embed", ids, "done"); err != nil {
		t.Fatal(err)
	}
	if n, err := s.ResetSkipped("embed"); err != nil || n != 0 {
		t.Fatalf("second reset = %d, %v", n, err)
	}
	if _, err := s.ResetSkipped("bogus"); err == nil {
		t.Fatal("want error for unknown kind")
	}
}

func TestThreadReaders(t *testing.T) {
	s, _ := open(t)
	now := time.Now()
	th, _ := seed(t, s, "hello", now)
	got, ok, err := s.GetThread(th.ID)
	if err != nil || !ok || got.Title != "Inbox" {
		t.Fatalf("GetThread = %+v %v %v", got, ok, err)
	}
	if _, ok, _ := s.GetThread("nope"); ok {
		t.Fatal("expected missing thread")
	}
	vs, err := s.ThreadVersions(th.ID, now.Add(-time.Hour))
	if err != nil || len(vs) != 1 || vs[0].Content != "hello" {
		t.Fatalf("ThreadVersions = %+v %v", vs, err)
	}
	if vs, _ := s.ThreadVersions(th.ID, now.Add(time.Hour)); len(vs) != 0 {
		t.Fatalf("window not applied: %+v", vs)
	}
	ts, err := s.ThreadsUpdatedSince(now.Add(-time.Hour), 10)
	if err != nil || len(ts) != 1 {
		t.Fatalf("ThreadsUpdatedSince = %+v %v", ts, err)
	}
}
