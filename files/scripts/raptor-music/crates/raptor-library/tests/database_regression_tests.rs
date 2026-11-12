use raptor_core::models::{AudioSourceKind, PlaybackAccess, PlaybackSource, PlaybackTarget, ProviderTrackRecord, Track, UnifiedTrack};
use raptor_library::{LibraryDatabase, QueueEntry};
use rusqlite::Connection;
use std::path::{Path, PathBuf};
use uuid::Uuid;

fn db_path(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("raptor_{}_{}.db", label, Uuid::new_v4()))
}

fn local_track(id: Uuid, path: &Path, title: &str) -> Track {
    Track {
        id,
        title: title.to_string(),
        artist: "Test Artist".to_string(),
        album: Some("Test Album".to_string()),
        duration_secs: Some(123),
        source: PlaybackSource::LocalFile { path: path.to_path_buf() },
    }
}

fn cleanup(path: &Path) {
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(path.with_extension("db-wal"));
    let _ = std::fs::remove_file(path.with_extension("db-shm"));
}

#[test]
fn repeated_local_upsert_updates_one_row() {
    let path = db_path("local_upsert");
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let media = path.with_file_name("same-track.flac");
        let id = LibraryDatabase::generate_stable_track_id(&media, "local");
        db.upsert_track(&local_track(id, &media, "Original")).unwrap();
        db.upsert_track(&local_track(id, &media, "Updated")).unwrap();

        let tracks = db.get_all_tracks().unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].title, "Updated");
    }
    cleanup(&path);
}

#[test]
fn remote_upsert_uses_provider_identity() {
    let path = db_path("remote_upsert");
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let make_track = |id, title: &str| Track {
            id,
            title: title.to_string(),
            artist: "Remote Artist".to_string(),
            album: None,
            duration_secs: Some(200),
            source: PlaybackSource::RemoteStream {
                provider_id: "provider-a".to_string(),
                provider_track_id: "track-42".to_string(),
            },
        };
        db.upsert_track(&make_track(Uuid::new_v4(), "First")).unwrap();
        db.upsert_track(&make_track(Uuid::new_v4(), "Second")).unwrap();
        let tracks = db.get_all_tracks().unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].title, "Second");
    }
    cleanup(&path);
}

#[test]
fn queue_and_playback_state_survive_reopen() {
    let path = db_path("reopen");
    let track_id = Uuid::new_v4();
    let queue_id = Uuid::new_v4();
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let media = path.with_file_name("persisted-track.mp3");
        db.upsert_track(&local_track(track_id, &media, "Persisted")).unwrap();
        db.save_queue(&[QueueEntry {
            queue_entry_id: queue_id,
            track_id,
            position: 7,
        }]).unwrap();
        db.set_state_value("current_track_id", &track_id.to_string()).unwrap();
        db.set_state_value("position_secs", "37").unwrap();
    }
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let queue = db.get_queue().unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].queue_entry_id, queue_id);
        assert_eq!(queue[0].track_id, track_id);
        assert_eq!(queue[0].position, 7);
        assert_eq!(db.get_state_value("current_track_id").unwrap().as_deref(), Some(track_id.to_string().as_str()));
        assert_eq!(db.get_state_value("position_secs").unwrap().as_deref(), Some("37"));
    }
    cleanup(&path);
}

#[test]
fn deleting_track_cascades_to_queue() {
    let path = db_path("cascade");
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let media = path.with_file_name("cascade-track.wav");
        let id = Uuid::new_v4();
        db.upsert_track(&local_track(id, &media, "Cascade")).unwrap();
        db.save_queue(&[QueueEntry {
            queue_entry_id: Uuid::new_v4(),
            track_id: id,
            position: 0,
        }]).unwrap();

        db.conn.execute("DELETE FROM tracks WHERE id = ?1", [id.to_string()]).unwrap();
        assert!(db.get_queue().unwrap().is_empty());
    }
    cleanup(&path);
}

#[test]
fn version_one_queue_migrates_without_losing_track_relationship() {
    let path = db_path("migration_v1");
    let track_id = Uuid::new_v4();
    {
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY NOT NULL, applied_at DATETIME DEFAULT CURRENT_TIMESTAMP);
             INSERT INTO schema_migrations (version) VALUES (1);
             CREATE TABLE tracks (
                 id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, artist TEXT NOT NULL,
                 album TEXT, duration_secs INTEGER, source_type TEXT NOT NULL,
                 source_uri TEXT, provider_id TEXT, provider_track_id TEXT,
                 created_at DATETIME DEFAULT CURRENT_TIMESTAMP
             );
             CREATE TABLE persistent_queue (
                 track_id TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0
             );"
        ).unwrap();
        conn.execute(
            "INSERT INTO tracks (id, title, artist, source_type, source_uri) VALUES (?1, 'Legacy', 'Artist', 'local', '/legacy.flac')",
            [track_id.to_string()],
        ).unwrap();
        conn.execute(
            "INSERT INTO persistent_queue (track_id, position) VALUES (?1, 4)",
            [track_id.to_string()],
        ).unwrap();
    }
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let queue = db.get_queue().unwrap();
        assert_eq!(queue.len(), 1);
        assert_eq!(queue[0].track_id, track_id);
        assert_eq!(queue[0].position, 4);
        assert_ne!(queue[0].queue_entry_id, Uuid::nil());
        let version: i32 = db.conn.query_row(
            "SELECT MAX(version) FROM schema_migrations", [], |row| row.get(0)
        ).unwrap();
        // Version 4 adds normalized UnifiedTrack persistence after imported-profile storage.
        assert_eq!(version, 4);
    }
    cleanup(&path);
}


#[test]
fn normalized_provider_tracks_round_trip_through_the_persistent_library_queue() {
    let path = db_path("unified_track");
    let track = UnifiedTrack::from_provider(
        ProviderTrackRecord {
            source: AudioSourceKind::Bandcamp,
            source_track_id: "123456".into(),
            title: "Night Drive".into(),
            artists: vec!["Independent Artist".into()],
            album: Some("After Hours".into()),
            artwork_url: Some("https://images.example.test/cover.jpg".into()),
            duration_secs: Some(184),
            isrc: None,
        },
        PlaybackAccess::EmbeddedPlayer,
        PlaybackTarget::EmbeddedPlayer {
            provider_id: "bandcamp".into(),
            content_id: "https://bandcamp.com/EmbeddedPlayer/track=123456/".into(),
        },
    );
    {
        let db = LibraryDatabase::new(&path).unwrap();
        db.upsert_unified_track(&track).unwrap();
        let loaded = db.get_unified_track(track.id).unwrap().unwrap();
        assert_eq!(loaded, track);

        // The legacy row remains available to old library readers during migration.
        let legacy = db.get_all_tracks().unwrap();
        assert_eq!(legacy.len(), 1);
        assert_eq!(legacy[0].id, track.id);
    }
    cleanup(&path);
}

#[test]
fn apple_music_library_refresh_updates_the_existing_connected_profile() {
    let path = db_path("apple_music_refresh");
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let first = db.save_imported_profile(
            "apple_music", Some("Apple Music Library"), Some("connected-account"),
            r#"{"saved_tracks":[{"title":"First"}]}"#,
        ).unwrap();
        let refreshed = db.save_imported_profile(
            "apple_music", Some("Apple Music Library"), Some("connected-account"),
            r#"{"saved_tracks":[{"title":"Second"}]}"#,
        ).unwrap();

        assert_eq!(first, refreshed);
        let profiles = db.get_imported_profiles().unwrap();
        assert_eq!(profiles.iter().filter(|profile| profile.provider == "apple_music").count(), 1);
        assert_eq!(
            db.get_imported_profile_payload(first).unwrap().as_deref(),
            Some(r#"{"saved_tracks":[{"title":"Second"}]}"#),
        );
    }
    cleanup(&path);
}

#[test]
fn playlist_names_must_not_be_empty() {
    let path = db_path("playlist_validation");
    {
        let db = LibraryDatabase::new(&path).unwrap();
        assert!(db.create_playlist("   ", None).is_err());
        let playlist_id = db.create_playlist("Valid", None).unwrap();
        assert!(db.rename_playlist(playlist_id, "  ").is_err());
        assert_eq!(db.get_playlists().unwrap()[0].name, "Valid");
    }
    cleanup(&path);
}

#[test]
fn playlists_create_order_remove_rename_and_persist() {
    let path = db_path("playlists");
    let first_id = Uuid::new_v4();
    let second_id = Uuid::new_v4();
    let playlist_id;
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let first_path = path.with_file_name("playlist-first.flac");
        let second_path = path.with_file_name("playlist-second.flac");
        db.upsert_track(&local_track(first_id, &first_path, "First")).unwrap();
        db.upsert_track(&local_track(second_id, &second_path, "Second")).unwrap();

        playlist_id = db.create_playlist("Favorites", Some("Saved tracks")).unwrap();
        db.add_track_to_playlist(playlist_id, second_id).unwrap();
        db.add_track_to_playlist(playlist_id, first_id).unwrap();

        let playlists = db.get_playlists().unwrap();
        assert_eq!(playlists.len(), 1);
        assert_eq!(playlists[0].name, "Favorites");
        assert_eq!(playlists[0].description.as_deref(), Some("Saved tracks"));

        let tracks = db.get_playlist_tracks(playlist_id).unwrap();
        assert_eq!(tracks.iter().map(|t| t.id).collect::<Vec<_>>(), vec![second_id, first_id]);

        db.move_track_in_playlist(playlist_id, 1, 0).unwrap();
        let reordered = db.get_playlist_tracks(playlist_id).unwrap();
        assert_eq!(reordered.iter().map(|t| t.id).collect::<Vec<_>>(), vec![first_id, second_id]);
        db.move_track_in_playlist(playlist_id, 0, 1).unwrap();

        db.remove_track_from_playlist(playlist_id, 0).unwrap();
        let tracks = db.get_playlist_tracks(playlist_id).unwrap();
        assert_eq!(tracks.iter().map(|t| t.id).collect::<Vec<_>>(), vec![first_id]);
        db.rename_playlist(playlist_id, "Pinned").unwrap();
    }
    {
        let db = LibraryDatabase::new(&path).unwrap();
        let playlists = db.get_playlists().unwrap();
        assert_eq!(playlists.len(), 1);
        assert_eq!(playlists[0].name, "Pinned");
        assert_eq!(db.get_playlist_tracks(playlist_id).unwrap()[0].id, first_id);
        db.delete_playlist(playlist_id).unwrap();
        assert!(db.get_playlists().unwrap().is_empty());
    }
    cleanup(&path);
}
