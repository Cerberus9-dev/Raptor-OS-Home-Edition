use raptor_core::models::{Track, PlaybackSource};
use rusqlite::{params, Connection};
use std::path::{Path, PathBuf};
use uuid::Uuid;
use thiserror::Error;
use sha2::{Sha256, Digest};

#[derive(Error, Debug)]
pub enum LibraryError {
    #[error("Database error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("UUID parse error: {0}")]
    Uuid(#[from] uuid::Error),
    #[error("Migration error: {0}")]
    Migration(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueueEntry {
    pub queue_entry_id: Uuid,
    pub track_id: Uuid,
    pub position: i32,
}

pub struct LibraryDatabase {
    pub conn: Connection,
}

impl LibraryDatabase {
    pub fn new(path: impl AsRef<Path>) -> Result<Self, LibraryError> {
        let conn = Connection::open(path)?;
        conn.execute("PRAGMA foreign_keys = ON;", [])?;
        let mut db = Self { conn };
        db.run_migrations()?;
        Ok(db)
    }

    pub fn run_migrations(&mut self) -> Result<(), LibraryError> {
        let tx = self.conn.transaction()?;

        tx.execute(
            r#"
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY NOT NULL,
                applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
            );
            "#,
            [],
        )?;

        let current_version: i32 = tx.query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |row| row.get(0),
        )?;

        if current_version < 1 {
            tx.execute_batch(
                r#"
                CREATE TABLE IF NOT EXISTS tracks (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    artist TEXT NOT NULL,
                    album TEXT,
                    duration_secs INTEGER,
                    source_type TEXT NOT NULL,
                    source_uri TEXT,
                    provider_id TEXT,
                    provider_track_id TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE IF NOT EXISTS playlists (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
                );

                CREATE TABLE IF NOT EXISTS playlist_tracks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    playlist_id TEXT NOT NULL,
                    track_id TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
                    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS persistent_queue (
                    queue_entry_id TEXT PRIMARY KEY NOT NULL,
                    track_id TEXT NOT NULL,
                    position INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
                );

                CREATE TABLE IF NOT EXISTS playback_state_persistence (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                );
                "#,
            )?;
            tx.execute("INSERT INTO schema_migrations (version) VALUES (1)", [])?;
        }

        if current_version < 2 {
            let has_col = |tx: &rusqlite::Transaction, col: &str| -> Result<bool, rusqlite::Error> {
                let count: i32 = tx.query_row(
                    &format!("SELECT COUNT(*) FROM pragma_table_info('tracks') WHERE name='{}'", col),
                    [],
                    |row| row.get(0),
                )?;
                Ok(count > 0)
            };

            if !has_col(&tx, "provider_id")? {
                tx.execute("ALTER TABLE tracks ADD COLUMN provider_id TEXT", [])?;
            }
            if !has_col(&tx, "provider_track_id")? {
                tx.execute("ALTER TABLE tracks ADD COLUMN provider_track_id TEXT", [])?;
            }
            if !has_col(&tx, "created_at")? {
                tx.execute("ALTER TABLE tracks ADD COLUMN created_at TEXT", [])?;
                tx.execute("UPDATE tracks SET created_at = datetime('now') WHERE created_at IS NULL", [])?;
            }

            let has_q_entry_id = tx.query_row(
                "SELECT COUNT(*) FROM pragma_table_info('persistent_queue') WHERE name='queue_entry_id'",
                [],
                |row| row.get::<_, i32>(0),
            )? > 0;

            if !has_q_entry_id {
                tx.execute_batch(
                    r#"
                    CREATE TABLE persistent_queue_new (
                        queue_entry_id TEXT PRIMARY KEY NOT NULL,
                        track_id TEXT NOT NULL,
                        position INTEGER NOT NULL DEFAULT 0,
                        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
                    );
                    INSERT INTO persistent_queue_new (queue_entry_id, track_id, position)
                    SELECT lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab',abs(random()) % 4 + 1,1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))), track_id, rowid FROM persistent_queue;
                    DROP TABLE persistent_queue;
                    ALTER TABLE persistent_queue_new RENAME TO persistent_queue;
                    "#,
                )?;
            }

            tx.execute(
                r#"
                CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_local 
                ON tracks(source_type, source_uri) WHERE source_type = 'local' AND source_uri IS NOT NULL;

                CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_remote 
                ON tracks(source_type, provider_id, provider_track_id) WHERE source_type = 'remote' AND provider_id IS NOT NULL AND provider_track_id IS NOT NULL;
                "#,
                [],
            )?;

            tx.execute("INSERT INTO schema_migrations (version) VALUES (2)", [])?;
        }

        tx.commit()?;
        Ok(())
    }

    pub fn generate_stable_track_id(path: &Path, source_type: &str) -> Uuid {
        let canonical_path = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        let path_bytes = canonical_path.to_string_lossy().into_owned();
        
        let mut hasher = Sha256::new();
        hasher.update(source_type.as_bytes());
        hasher.update(b":");
        hasher.update(path_bytes.as_bytes());
        let result = hasher.finalize();

        let mut bytes = [0u8; 16];
        bytes.copy_from_slice(&result[0..16]);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;

        Uuid::from_bytes(bytes)
    }

    pub fn upsert_track(&self, track: &Track) -> Result<(), LibraryError> {
        match &track.source {
            PlaybackSource::LocalFile { path } => {
                let canon = std::fs::canonicalize(path).unwrap_or_else(|_| path.clone());
                let source_uri = canon.to_string_lossy().to_string();
                self.conn.execute(
                    r#"
                    INSERT INTO tracks (id, title, artist, album, duration_secs, source_type, source_uri, provider_id, provider_track_id)
                    VALUES (?1, ?2, ?3, ?4, ?5, 'local', ?6, NULL, NULL)
                    ON CONFLICT(source_type, source_uri) WHERE source_type = 'local' AND source_uri IS NOT NULL DO UPDATE SET
                        title = excluded.title,
                        artist = excluded.artist,
                        album = excluded.album,
                        duration_secs = excluded.duration_secs
                    "#,
                    params![
                        track.id.to_string(),
                        track.title,
                        track.artist,
                        track.album,
                        track.duration_secs,
                        source_uri
                    ],
                )?;
            }
            PlaybackSource::RemoteStream { provider_id, provider_track_id } => {
                self.conn.execute(
                    r#"
                    INSERT INTO tracks (id, title, artist, album, duration_secs, source_type, source_uri, provider_id, provider_track_id)
                    VALUES (?1, ?2, ?3, ?4, ?5, 'remote', NULL, ?6, ?7)
                    ON CONFLICT(source_type, provider_id, provider_track_id) WHERE source_type = 'remote' AND provider_id IS NOT NULL AND provider_track_id IS NOT NULL DO UPDATE SET
                        title = excluded.title,
                        artist = excluded.artist,
                        album = excluded.album,
                        duration_secs = excluded.duration_secs
                    "#,
                    params![
                        track.id.to_string(),
                        track.title,
                        track.artist,
                        track.album,
                        track.duration_secs,
                        provider_id,
                        provider_track_id
                    ],
                )?;
            }
            PlaybackSource::Unknown { raw_type } => {
                self.conn.execute(
                    r#"
                    INSERT INTO tracks (id, title, artist, album, duration_secs, source_type, source_uri, provider_id, provider_track_id)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL, NULL)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        artist = excluded.artist
                    "#,
                    params![
                        track.id.to_string(),
                        track.title,
                        track.artist,
                        track.album,
                        track.duration_secs,
                        raw_type
                    ],
                )?;
            }
        }
        Ok(())
    }

    pub fn get_all_tracks(&self) -> Result<Vec<Track>, LibraryError> {
        let mut stmt = self.conn.prepare("SELECT id, title, artist, album, duration_secs, source_type, source_uri, provider_id, provider_track_id FROM tracks ORDER BY created_at ASC, id ASC")?;
        let track_iter = stmt.query_map([], |row| {
            let id_str: String = row.get(0)?;
            let title: String = row.get(1)?;
            let artist: String = row.get(2)?;
            let album: Option<String> = row.get(3)?;
            let duration_secs: Option<u64> = row.get(4)?;
            let source_type: String = row.get(5)?;
            let source_uri: Option<String> = row.get(6)?;
            let provider_id: Option<String> = row.get(7)?;
            let provider_track_id: Option<String> = row.get(8)?;

            let source = if source_type == "local" {
                PlaybackSource::LocalFile { path: PathBuf::from(source_uri.unwrap_or_default()) }
            } else if source_type == "remote" {
                PlaybackSource::RemoteStream {
                    provider_id: provider_id.unwrap_or_else(|| "unknown".into()),
                    provider_track_id: provider_track_id.unwrap_or_default(),
                }
            } else {
                PlaybackSource::Unknown { raw_type: source_type }
            };

            let id = Uuid::parse_str(&id_str).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?;

            Ok(Track {
                id,
                title,
                artist,
                album,
                duration_secs,
                source,
            })
        })?;

        let mut tracks = Vec::new();
        for t in track_iter {
            tracks.push(t.map_err(|e| match e {
                rusqlite::Error::FromSqlConversionFailure(_, _, boxed) => {
                    if let Ok(uuid_err) = boxed.downcast::<uuid::Error>() {
                        LibraryError::Uuid(*uuid_err)
                    } else {
                        LibraryError::Sqlite(e)
                    }
                }
                other => LibraryError::Sqlite(other),
            })?);
        }
        Ok(tracks)
    }

    pub fn save_queue(&self, entries: &[QueueEntry]) -> Result<(), LibraryError> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute("DELETE FROM persistent_queue", [])?;
        {
            let mut stmt = tx.prepare("INSERT INTO persistent_queue (queue_entry_id, track_id, position) VALUES (?1, ?2, ?3)")?;
            for entry in entries {
                stmt.execute(params![entry.queue_entry_id.to_string(), entry.track_id.to_string(), entry.position])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn get_queue(&self) -> Result<Vec<QueueEntry>, LibraryError> {
        let mut stmt = self.conn.prepare("SELECT queue_entry_id, track_id, position FROM persistent_queue ORDER BY position ASC, queue_entry_id ASC")?;
        let rows = stmt.query_map([], |row| {
            let qid: String = row.get(0)?;
            let tid: String = row.get(1)?;
            let pos: i32 = row.get(2)?;
            let queue_entry_id = Uuid::parse_str(&qid).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?;
            let track_id = Uuid::parse_str(&tid).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    1,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?;
            Ok(QueueEntry {
                queue_entry_id,
                track_id,
                position: pos,
            })
        })?;
        let mut queue = Vec::new();
        for r in rows {
            queue.push(r.map_err(|e| match e {
                rusqlite::Error::FromSqlConversionFailure(_, _, boxed) => {
                    if let Ok(uuid_err) = boxed.downcast::<uuid::Error>() {
                        LibraryError::Uuid(*uuid_err)
                    } else {
                        LibraryError::Sqlite(e)
                    }
                }
                other => LibraryError::Sqlite(other),
            })?);
        }
        Ok(queue)
    }

    pub fn set_state_value(&self, key: &str, value: &str) -> Result<(), LibraryError> {
        self.conn.execute(
            "INSERT INTO playback_state_persistence (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn get_state_value(&self, key: &str) -> Result<Option<String>, LibraryError> {
        let mut stmt = self.conn.prepare("SELECT value FROM playback_state_persistence WHERE key = ?1")?;
        let mut rows = stmt.query(params![key])?;
        if let Some(row) = rows.next()? {
            Ok(Some(row.get(0)?))
        } else {
            Ok(None)
        }
    }
}
