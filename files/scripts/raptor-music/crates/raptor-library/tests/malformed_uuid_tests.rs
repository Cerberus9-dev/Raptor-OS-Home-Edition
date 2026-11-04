use raptor_library::{LibraryDatabase, LibraryError};
use rusqlite::Connection;
use uuid::Uuid;

#[test]
fn test_malformed_persisted_uuid_produces_error() {
    let db_path = std::env::temp_dir().join(format!("raptor_malformed_uuid_{}.db", Uuid::new_v4()));
    let _ = std::fs::remove_file(&db_path);

    {
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE tracks (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                album TEXT,
                duration_secs INTEGER,
                source_type TEXT NOT NULL,
                source_uri TEXT,
                provider_id TEXT,
                provider_track_id TEXT,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            );
            CREATE TABLE persistent_queue (
                queue_entry_id TEXT PRIMARY KEY NOT NULL,
                track_id TEXT NOT NULL,
                position INTEGER NOT NULL
            );
            INSERT INTO tracks VALUES ('not-a-uuid', 'Title', 'Artist', NULL, 180, 'local', '/music/a.mp3', NULL, NULL, '2026-01-01 00:00:00');
            INSERT INTO persistent_queue VALUES ('also-not-a-uuid', 'not-a-uuid', 0);
            "#,
        ).unwrap();
    }

    let db = LibraryDatabase::new(&db_path).unwrap();
    let queue_res = db.get_queue();
    assert!(matches!(queue_res, Err(LibraryError::Uuid(_))), "Malformed UUID in persistent_queue must return LibraryError::Uuid");

    let tracks_res = db.get_all_tracks();
    assert!(matches!(tracks_res, Err(LibraryError::Uuid(_))), "Malformed UUID in tracks must return LibraryError::Uuid");

    let _ = std::fs::remove_file(&db_path);
}
