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
    #[error("Validation error: {0}")]
    Validation(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct QueueEntry {
    pub queue_entry_id: Uuid,
    pub track_id: Uuid,
    pub position: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Playlist {
    pub id: Uuid,
    pub name: String,
    pub description: Option<String>,
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

            // This migration creates two indexes. execute() accepts one SQL
            // statement; execute_batch() is required for the pair. Keeping both
            // statements inside the migration transaction makes the migration
            // atomic and allows a fresh database to finish initialization.
            tx.execute_batch(
                r#"
                CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_local
                ON tracks(source_type, source_uri)
                WHERE source_type = 'local' AND source_uri IS NOT NULL;

                CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_remote
                ON tracks(source_type, provider_id, provider_track_id)
                WHERE source_type = 'remote'
                  AND provider_id IS NOT NULL
                  AND provider_track_id IS NOT NULL;
                "#,
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

            // query_map rows are rusqlite::Result, so return the raw string and
            // parse the UUID after the row has been read.
            Ok((id_str, title, artist, album, duration_secs, source))
        })?;

        let mut tracks = Vec::new();
        for row in track_iter {
            let (id_str, title, artist, album, duration_secs, source) = row?;
            let id = Uuid::parse_str(&id_str)?;
            tracks.push(Track {
                id,
                title,
                artist,
                album,
                duration_secs,
                source,
            });
        }
        Ok(tracks)
    }

    pub fn create_playlist(&self, name: &str, description: Option<&str>) -> Result<Uuid, LibraryError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(LibraryError::Validation("Playlist name cannot be empty".into()));
        }
        let id = Uuid::new_v4();
        self.conn.execute(
            "INSERT INTO playlists (id, name, description) VALUES (?1, ?2, ?3)",
            params![id.to_string(), name, description],
        )?;
        Ok(id)
    }

    pub fn get_playlists(&self) -> Result<Vec<Playlist>, LibraryError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, description FROM playlists ORDER BY created_at ASC, name COLLATE NOCASE ASC"
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, Option<String>>(2)?))
        })?;
        let mut playlists = Vec::new();
        for row in rows {
            let (id, name, description) = row?;
            playlists.push(Playlist { id: Uuid::parse_str(&id)?, name, description });
        }
        Ok(playlists)
    }

    pub fn rename_playlist(&self, playlist_id: Uuid, name: &str) -> Result<(), LibraryError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(LibraryError::Validation("Playlist name cannot be empty".into()));
        }
        self.conn.execute(
            "UPDATE playlists SET name = ?1 WHERE id = ?2",
            params![name, playlist_id.to_string()],
        )?;
        Ok(())
    }

    pub fn delete_playlist(&self, playlist_id: Uuid) -> Result<(), LibraryError> {
        self.conn.execute("DELETE FROM playlists WHERE id = ?1", [playlist_id.to_string()])?;
        Ok(())
    }

    pub fn add_track_to_playlist(&self, playlist_id: Uuid, track_id: Uuid) -> Result<(), LibraryError> {
        let tx = self.conn.unchecked_transaction()?;
        let position: i32 = tx.query_row(
            "SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_tracks WHERE playlist_id = ?1",
            [playlist_id.to_string()],
            |row| row.get(0),
        )?;
        tx.execute(
            "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?1, ?2, ?3)",
            params![playlist_id.to_string(), track_id.to_string(), position],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn get_playlist_tracks(&self, playlist_id: Uuid) -> Result<Vec<Track>, LibraryError> {
        let mut stmt = self.conn.prepare(
            "SELECT track_id FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position ASC, id ASC"
        )?;
        let rows = stmt.query_map([playlist_id.to_string()], |row| row.get::<_, String>(0))?;
        let mut ordered_ids = Vec::new();
        for row in rows {
            ordered_ids.push(Uuid::parse_str(&row?)?);
        }

        let tracks = self.get_all_tracks()?;
        Ok(ordered_ids.into_iter().filter_map(|id| {
            tracks.iter().find(|track| track.id == id).cloned()
        }).collect())
    }

    /// Move a playlist entry to a new zero-based position without changing
    /// its track identity or disturbing the relative order of other entries.
    pub fn move_track_in_playlist(
        &self,
        playlist_id: Uuid,
        from_position: i32,
        to_position: i32,
    ) -> Result<(), LibraryError> {
        if from_position < 0 || to_position < 0 {
            return Err(LibraryError::Validation("Playlist positions cannot be negative".into()));
        }

        let tx = self.conn.unchecked_transaction()?;
        let mut stmt = tx.prepare(
            "SELECT id FROM playlist_tracks WHERE playlist_id = ?1 ORDER BY position ASC, id ASC"
        )?;
        let rows = stmt.query_map([playlist_id.to_string()], |row| row.get::<_, i64>(0))?;
        let mut entry_ids = Vec::new();
        for row in rows {
            entry_ids.push(row?);
        }
        drop(stmt);

        let from = from_position as usize;
        let to = to_position as usize;
        if from >= entry_ids.len() || to >= entry_ids.len() {
            return Err(LibraryError::Validation("Playlist position is out of range".into()));
        }

        let moved = entry_ids.remove(from);
        entry_ids.insert(to, moved);
        for (position, entry_id) in entry_ids.iter().enumerate() {
            tx.execute(
                "UPDATE playlist_tracks SET position = ?1 WHERE id = ?2",
                params![position as i32, entry_id],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn remove_track_from_playlist(&self, playlist_id: Uuid, position: i32) -> Result<(), LibraryError> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM playlist_tracks WHERE playlist_id = ?1 AND position = ?2",
            params![playlist_id.to_string(), position],
        )?;
        tx.execute(
            "UPDATE playlist_tracks SET position = position - 1 WHERE playlist_id = ?1 AND position > ?2",
            params![playlist_id.to_string(), position],
        )?;
        tx.commit()?;
        Ok(())
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
            Ok((qid, tid, pos))
        })?;
        let mut queue = Vec::new();
        for row in rows {
            let (qid, tid, pos) = row?;
            let queue_entry_id = Uuid::parse_str(&qid)?;
            let track_id = Uuid::parse_str(&tid)?;
            queue.push(QueueEntry {
                queue_entry_id,
                track_id,
                position: pos,
            });
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

#[cfg(test)]
mod migration_tests {
    use super::*;

    #[test]
    fn fresh_database_applies_all_migrations_and_creates_track_indexes() {
        let db = LibraryDatabase::new(":memory:")
            .expect("a fresh in-memory library database should initialize");

        let version: i32 = db.conn.query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |row| row.get(0),
        ).expect("migration version should be readable");
        assert_eq!(version, 2, "fresh database should reach schema version 2");

        let index_count: i64 = db.conn.query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index'
               AND name IN ('idx_tracks_local', 'idx_tracks_remote')",
            [],
            |row| row.get(0),
        ).expect("track indexes should be queryable");
        assert_eq!(index_count, 2, "both partial unique indexes should exist");
    }
}
