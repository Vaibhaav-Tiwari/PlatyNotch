package store

// migrations are applied in order, once each, recorded in schema_migrations.
// Never edit a shipped migration; append a new one.
var migrations = []string{`
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  app_bundle TEXT NOT NULL,
  app_name TEXT NOT NULL DEFAULT '',
  key TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (app_bundle, key)
);
CREATE TABLE versions (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  hour_bucket INTEGER NOT NULL,
  content TEXT NOT NULL,
  content_hash TEXT NOT NULL DEFAULT '',
  chars INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE (thread_id, hour_bucket)
);
CREATE TABLE chunks (
  id INTEGER PRIMARY KEY,
  version_id TEXT NOT NULL REFERENCES versions(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  idx INTEGER NOT NULL,
  text TEXT NOT NULL,
  captured_at INTEGER NOT NULL,
  embed_status TEXT NOT NULL DEFAULT 'pending',
  extract_status TEXT NOT NULL DEFAULT 'pending'
);
CREATE INDEX chunks_version ON chunks(version_id);
CREATE INDEX chunks_captured ON chunks(captured_at);
CREATE VIRTUAL TABLE chunks_fts USING fts5(text, content='chunks', content_rowid='id');
CREATE TRIGGER chunks_ai AFTER INSERT ON chunks BEGIN
  INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER chunks_ad AFTER DELETE ON chunks BEGIN
  INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
END;
CREATE TRIGGER chunks_au AFTER UPDATE OF text ON chunks BEGIN
  INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
  INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TABLE chunk_vectors (
  chunk_id INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
  model TEXT NOT NULL,
  dim INTEGER NOT NULL,
  vec BLOB NOT NULL
);
CREATE TABLE loops (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  details TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',
  source_app TEXT NOT NULL DEFAULT '',
  source_thread TEXT NOT NULL DEFAULT '',
  quote TEXT NOT NULL DEFAULT '',
  due_at INTEGER,
  detected_at INTEGER NOT NULL,
  resolved_at INTEGER,
  evidence TEXT NOT NULL DEFAULT '',
  title_hash TEXT NOT NULL UNIQUE
);
CREATE TABLE retry_queue (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  chunk_id INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_at INTEGER NOT NULL,
  last_error TEXT NOT NULL DEFAULT ''
);
`}
