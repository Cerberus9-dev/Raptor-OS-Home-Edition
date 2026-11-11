//! Normalized, privacy-conscious profile migration model.
//!
//! This module deliberately parses exported data rather than scraping source
//! services. Provider adapters can normalize their official export/API payloads
//! into this model before the library persists the import.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ImportedProfile {
    pub source: String,
    pub display_name: Option<String>,
    pub username: Option<String>,
    pub biography: Option<String>,
    pub avatar_url: Option<String>,
    pub playlists: Vec<ImportedPlaylist>,
    pub saved_tracks: Vec<ImportedTrack>,
    pub followed_artists: Vec<ImportedArtist>,
    #[serde(default)]
    pub library_artists: Vec<ImportedArtist>,
    pub listening_history: Vec<ImportedListen>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ImportedPlaylist {
    pub source_id: Option<String>,
    pub name: String,
    pub description: Option<String>,
    pub artwork_url: Option<String>,
    pub tracks: Vec<ImportedTrack>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ImportedTrack {
    pub source_id: Option<String>,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportedArtist {
    pub source_id: Option<String>,
    pub name: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportedListen {
    pub track: ImportedTrack,
    pub played_at: Option<String>,
    /// Playback duration reported by the source export, in milliseconds.
    pub ms_played: Option<u64>,
    pub play_count: u32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportSummary {
    pub playlists: usize,
    pub playlist_tracks: usize,
    pub saved_tracks: usize,
    pub followed_artists: usize,
    pub library_artists: usize,
    pub listening_events: usize,
    pub has_profile_image: bool,
}

pub fn parse_profile_export(payload: &str) -> Result<ImportedProfile, String> {
    let root: Value = serde_json::from_str(payload)
        .map_err(|_| "The selected file is not valid JSON".to_string())?;

    if root.is_array() {
        return parse_spotify_history(&root);
    }

    if let Some(profile) = root.get("raptor_music_profile") {
        return parse_raptor_package(profile);
    }

    // Spotify's downloadable account export commonly separates playlists
    // (playlists[].items[].track) and saved tracks (tracks[].track) into JSON
    // documents. Accept either document independently; importing a directory
    // can combine them through the same normalized model in a later UI step.
    if root.get("playlists").and_then(Value::as_array).is_some() {
        return parse_spotify_playlists(&root);
    }
    if root.get("tracks").and_then(Value::as_array).is_some() {
        return parse_spotify_library(&root);
    }

    Err("Unsupported export format. Choose a Raptor Music profile package or a supported service export.".into())
}

fn parse_raptor_package(value: &Value) -> Result<ImportedProfile, String> {
    let mut profile = ImportedProfile {
        source: string(value, "source").unwrap_or_else(|| "Imported profile".into()),
        display_name: string(value, "display_name"),
        username: string(value, "username"),
        biography: string(value, "biography"),
        avatar_url: safe_https_url(string(value, "avatar_url")),
        ..ImportedProfile::default()
    };

    if let Some(rows) = value.get("playlists").and_then(Value::as_array) {
        for row in rows {
            let name = string(row, "name").unwrap_or_default();
            if name.trim().is_empty() { continue; }
            let tracks = row.get("tracks").and_then(Value::as_array)
                .map(|items| items.iter().filter_map(parse_normalized_track).collect())
                .unwrap_or_default();
            profile.playlists.push(ImportedPlaylist {
                source_id: string(row, "source_id"),
                name,
                description: string(row, "description"),
                artwork_url: safe_https_url(string(row, "artwork_url")),
                tracks,
            });
        }
    }

    if let Some(rows) = value.get("saved_tracks").and_then(Value::as_array) {
        profile.saved_tracks = rows.iter().filter_map(parse_normalized_track).collect();
    }
    if let Some(rows) = value.get("followed_artists").and_then(Value::as_array) {
        profile.followed_artists = rows.iter().filter_map(|row| {
            let name = string(row, "name")?;
            if name.trim().is_empty() { return None; }
            Some(ImportedArtist { source_id: string(row, "source_id"), name })
        }).collect();
    }
    if let Some(rows) = value.get("library_artists").and_then(Value::as_array) {
        profile.library_artists = rows.iter().filter_map(|row| {
            let name = string(row, "name")?;
            if name.trim().is_empty() { return None; }
            Some(ImportedArtist { source_id: string(row, "source_id"), name })
        }).collect();
    }
    if let Some(rows) = value.get("listening_history").and_then(Value::as_array) {
        profile.listening_history = rows.iter().filter_map(|row| {
            let track = parse_normalized_track(row)?;
            Some(ImportedListen {
                track,
                played_at: string(row, "played_at"),
                ms_played: row.get("ms_played").and_then(Value::as_u64),
                play_count: row.get("play_count").and_then(Value::as_u64).unwrap_or(1).min(u32::MAX as u64) as u32,
            })
        }).collect();
    }
    deduplicate_profile(&mut profile);
    Ok(profile)
}

fn parse_spotify_playlists(root: &Value) -> Result<ImportedProfile, String> {
    let rows = root.get("playlists").and_then(Value::as_array)
        .ok_or_else(|| "No playlists were found in this export".to_string())?;
    let mut profile = ImportedProfile { source: "Spotify export".into(), ..ImportedProfile::default() };
    for row in rows {
        let name = string(row, "name").unwrap_or_default();
        if name.trim().is_empty() { continue; }
        // Accept both Spotify's native items[].track export shape and
        // normalized profile packages that store tracks[] directly.
        let tracks = row.get("items").or_else(|| row.get("tracks"))
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(|item| {
                if let Some(track) = item.get("track") {
                    parse_spotify_track(track)
                } else {
                    parse_normalized_track(item).or_else(|| parse_spotify_track(item))
                }
            }).collect())
            .unwrap_or_default();
        profile.playlists.push(ImportedPlaylist {
            source_id: string(row, "uri").or_else(|| string(row, "playlist_id")).or_else(|| string(row, "id")),
            name,
            description: string(row, "description"),
            artwork_url: None,
            tracks,
        });
    }
    deduplicate_profile(&mut profile);
    Ok(profile)
}

fn parse_spotify_library(root: &Value) -> Result<ImportedProfile, String> {
    let rows = root.get("tracks").and_then(Value::as_array)
        .ok_or_else(|| "No saved tracks were found in this export".to_string())?;
    let mut profile = ImportedProfile { source: "Spotify export".into(), ..ImportedProfile::default() };
    profile.saved_tracks = rows.iter().filter_map(|row| {
        let track = row.get("track").unwrap_or(row);
        parse_spotify_track(track)
    }).collect();
    deduplicate_profile(&mut profile);
    Ok(profile)
}


/// Spotify's extended streaming-history exports (for example
/// StreamingHistory_music_*.json and endsong_*.json) are top-level arrays,
/// unlike Spotify's playlist and saved-library exports.
fn parse_spotify_history(root: &Value) -> Result<ImportedProfile, String> {
    let rows = root.as_array()
        .ok_or_else(|| "Spotify listening history must be a JSON array".to_string())?;
    let mut profile = ImportedProfile {
        source: "Spotify extended listening history".into(),
        ..ImportedProfile::default()
    };

    for row in rows {
        // Spotify has shipped two materially different extended-history
        // schemas. Newer endsong exports use snake_case metadata fields;
        // older StreamingHistory_music exports use camelCase fields.
        let title = string(row, "master_metadata_track_name")
            .or_else(|| string(row, "trackName"));
        let artist = string(row, "master_metadata_album_artist_name")
            .or_else(|| string(row, "artistName"));
        // Podcast episodes and rows without music metadata are deliberately
        // skipped rather than being mislabeled as songs.
        let (Some(title), Some(artist)) = (title, artist) else { continue };
        let track = ImportedTrack {
            source_id: string(row, "spotify_track_uri")
                .or_else(|| string(row, "trackURI")),
            title,
            artist,
            album: string(row, "master_metadata_album_album_name")
                .or_else(|| string(row, "albumName")),
        };
        profile.listening_history.push(ImportedListen {
            track,
            played_at: string(row, "ts").or_else(|| string(row, "endTime")),
            ms_played: row.get("ms_played").and_then(Value::as_u64)
                .or_else(|| row.get("msPlayed").and_then(Value::as_u64)),
            play_count: 1,
        });
    }

    let mut seen = HashSet::new();
    profile.listening_history.retain(|listen| {
        let key = (
            listen.track.source_id.clone(),
            listen.track.title.to_lowercase(),
            listen.track.artist.to_lowercase(),
            listen.track.album.as_deref().unwrap_or("").to_lowercase(),
            listen.played_at.clone(),
            listen.ms_played,
        );
        seen.insert(key)
    });
    Ok(profile)
}

fn parse_spotify_track(value: &Value) -> Option<ImportedTrack> {
    let title = string(value, "trackName").or_else(|| string(value, "name"))?;
    let artist = string(value, "artistName").or_else(|| {
        value.get("artists").and_then(Value::as_array)
            .and_then(|artists| artists.first())
            .and_then(|artist| string(artist, "name"))
    }).unwrap_or_else(|| "Unknown artist".into());
    Some(ImportedTrack {
        source_id: string(value, "trackUri").or_else(|| string(value, "uri")),
        title,
        artist,
        album: string(value, "albumName").or_else(|| string(value, "album").or_else(|| {
            value.get("album").and_then(|album| string(album, "name"))
        })),
    })
}

fn parse_normalized_track(value: &Value) -> Option<ImportedTrack> {
    let title = string(value, "title")?;
    let artist = string(value, "artist").unwrap_or_else(|| "Unknown artist".into());
    Some(ImportedTrack {
        source_id: string(value, "source_id"),
        title,
        artist,
        album: string(value, "album"),
    })
}

fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str)
        .map(str::trim).filter(|s| !s.is_empty()).map(ToOwned::to_owned)
}

fn safe_https_url(value: Option<String>) -> Option<String> {
    value.filter(|value| {
        if value.len() > 2048 || value.chars().any(char::is_control) {
            return false;
        }
        let Ok(url) = url::Url::parse(value) else { return false; };
        url.scheme() == "https"
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none()
    })
}

fn deduplicate_profile(profile: &mut ImportedProfile) {
    deduplicate_playlists(&mut profile.playlists);
    for playlist in &mut profile.playlists {
        deduplicate_tracks(&mut playlist.tracks);
    }
    deduplicate_tracks(&mut profile.saved_tracks);
    let mut artists = HashSet::new();
    profile.followed_artists.retain(|artist| artists.insert(artist.name.to_lowercase()));
    let mut library_artists = HashSet::new();
    profile.library_artists.retain(|artist| library_artists.insert(artist.name.to_lowercase()));
    let mut listens = HashSet::new();
    profile.listening_history.retain(|listen| {
        let key = (
            listen.track.source_id.clone(),
            listen.track.title.to_lowercase(),
            listen.track.artist.to_lowercase(),
            listen.track.album.as_deref().unwrap_or("").to_lowercase(),
            listen.played_at.clone(),
            listen.ms_played,
        );
        listens.insert(key)
    });
}

fn deduplicate_playlists(playlists: &mut Vec<ImportedPlaylist>) {
    let mut positions: HashMap<String, usize> = HashMap::new();
    let mut merged: Vec<ImportedPlaylist> = Vec::with_capacity(playlists.len());

    for mut playlist in playlists.drain(..) {
        let Some(source_id) = playlist.source_id.clone().filter(|id| !id.trim().is_empty()) else {
            // Name-only playlists can legitimately share a title; without a
            // stable provider ID, preserve them as separate collections.
            merged.push(playlist);
            continue;
        };

        if let Some(index) = positions.get(&source_id).copied() {
            let existing = &mut merged[index];
            if existing.description.is_none() {
                existing.description = playlist.description.take();
            }
            if existing.artwork_url.is_none() {
                existing.artwork_url = playlist.artwork_url.take();
            }
            existing.tracks.append(&mut playlist.tracks);
            deduplicate_tracks(&mut existing.tracks);
        } else {
            positions.insert(source_id, merged.len());
            merged.push(playlist);
        }
    }

    *playlists = merged;
}

fn deduplicate_tracks(tracks: &mut Vec<ImportedTrack>) {
    let mut seen = HashSet::new();
    tracks.retain(|track| {
        let key = track.source_id.as_ref().map(|id| format!("id:{id}"))
            .unwrap_or_else(|| format!("{}\0{}\0{}", track.title.to_lowercase(), track.artist.to_lowercase(), track.album.as_deref().unwrap_or("").to_lowercase()));
        seen.insert(key)
    });
}

impl ImportedProfile {
    /// Merge another export document into this profile, retaining the first
    /// available identity fields and avoiding repeated collections/events.
    pub fn merge(&mut self, mut other: ImportedProfile) {
        if self.source.is_empty() { self.source = other.source; }
        if self.display_name.is_none() { self.display_name = other.display_name.take(); }
        if self.username.is_none() { self.username = other.username.take(); }
        if self.biography.is_none() { self.biography = other.biography.take(); }
        if self.avatar_url.is_none() { self.avatar_url = other.avatar_url.take(); }

        self.playlists.append(&mut other.playlists);
        self.saved_tracks.append(&mut other.saved_tracks);
        self.followed_artists.append(&mut other.followed_artists);
        self.library_artists.append(&mut other.library_artists);
        self.listening_history.append(&mut other.listening_history);
        deduplicate_profile(self);
    }

    pub fn summary(&self) -> ImportSummary {
        ImportSummary {
            playlists: self.playlists.len(),
            playlist_tracks: self.playlists.iter().map(|p| p.tracks.len()).sum(),
            saved_tracks: self.saved_tracks.len(),
            followed_artists: self.followed_artists.len(),
            library_artists: self.library_artists.len(),
            listening_events: self.listening_history.len(),
            has_profile_image: self.avatar_url.is_some(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_profile_identity_and_all_collection_types() {
        let json = r#"{
          "raptor_music_profile": {
            "source": "Example Service",
            "display_name": "Listener",
            "username": "listener",
            "biography": "Independent music fan",
            "avatar_url": "https://cdn.example/avatar.png",
            "playlists": [{"source_id":"p1","name":"Night drive","tracks":[
              {"source_id":"t1","title":"Track","artist":"Artist","album":"Record"}
            ]}],
            "saved_tracks": [{"title":"Saved","artist":"Singer"}],
            "followed_artists": [{"name":"Singer"}],
            "listening_history": [{"title":"Played","artist":"Band","played_at":"2026-01-01T12:00:00Z","play_count":3}]
          }
        }"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.display_name.as_deref(), Some("Listener"));
        assert_eq!(profile.avatar_url.as_deref(), Some("https://cdn.example/avatar.png"));
        assert_eq!(profile.summary(), ImportSummary {
            playlists: 1, playlist_tracks: 1, saved_tracks: 1,
            followed_artists: 1, library_artists: 0, listening_events: 1, has_profile_image: true,
        });
        assert_eq!(profile.listening_history[0].play_count, 3);
    }

    #[test]
    fn parses_apple_library_artists_separately_from_followed_artists() {
        let json = r#"{ "raptor_music_profile": {
            "source": "Apple Music",
            "library_artists": [{"source_id":"artist-1","name":"Saved Artist"}]
        }}"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.followed_artists.len(), 0);
        assert_eq!(profile.library_artists.len(), 1);
        assert_eq!(profile.library_artists[0].name, "Saved Artist");
    }

    #[test]
    fn older_saved_profiles_without_library_artists_remain_readable() {
        let json = r#"{ "raptor_music_profile": { "source":"Old import", "followed_artists":[] } }"#;
        let profile = parse_profile_export(json).unwrap();
        assert!(profile.library_artists.is_empty());
    }

    #[test]
    fn parses_spotify_playlist_export_and_preserves_order() {
        let json = r#"{"playlists":[{"name":"Mix","items":[
          {"track":{"trackName":"First","artistName":"A","albumName":"One","trackUri":"spotify:track:1"}},
          {"track":{"trackName":"Second","artistName":"B","albumName":"Two","trackUri":"spotify:track:2"}}
        ]}]}"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.source, "Spotify export");
        assert_eq!(profile.playlists[0].tracks[0].title, "First");
        assert_eq!(profile.playlists[0].tracks[1].title, "Second");
    }

    #[test]
    fn spotify_playlist_export_accepts_playlist_ids_and_merges_duplicate_ids() {
        let json = r#"{"playlists":[
          {"playlist_id":"playlist-123","name":"Mix","items":[
            {"track":{"trackName":"One","artistName":"A","trackUri":"track-1"}}
          ]},
          {"id":"playlist-123","name":"Mix","items":[
            {"track":{"trackName":"Two","artistName":"B","trackUri":"track-2"}}
          ]}
        ]}"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.playlists.len(), 1);
        assert_eq!(profile.playlists[0].source_id.as_deref(), Some("playlist-123"));
        assert_eq!(profile.playlists[0].tracks.len(), 2);
        assert_eq!(profile.playlists[0].tracks[1].title, "Two");
    }

    #[test]
    fn playlists_without_stable_ids_are_not_collapsed_by_name() {
        let json = r#"{"playlists":[
          {"name":"Favorites","items":[]},
          {"name":"Favorites","items":[]}
        ]}"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.playlists.len(), 2);
    }

    #[test]
    fn profile_artwork_requires_a_well_formed_https_url_without_credentials() {
        assert_eq!(safe_https_url(Some("https://cdn.example/avatar.png".into())).as_deref(), Some("https://cdn.example/avatar.png"));
        assert!(safe_https_url(Some("https://user:pass@cdn.example/avatar.png".into())).is_none());
        assert!(safe_https_url(Some("https://".into())).is_none());
        assert!(safe_https_url(Some("http://cdn.example/avatar.png".into())).is_none());
        assert!(safe_https_url(Some(format!("https://cdn.example/{}", "a".repeat(2048)))).is_none());
    }

    #[test]
    fn listening_history_dedup_keeps_distinct_tracks_without_provider_ids() {
        let json = r#"[
          {"ts":"2026-10-01T12:00:00Z","ms_played":1000,"master_metadata_track_name":"First","master_metadata_album_artist_name":"Artist"},
          {"ts":"2026-10-01T12:00:00Z","ms_played":1000,"master_metadata_track_name":"Second","master_metadata_album_artist_name":"Artist"},
          {"ts":"2026-10-01T12:00:00Z","ms_played":1000,"master_metadata_track_name":"First","master_metadata_album_artist_name":"Artist"}
        ]"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.listening_history.len(), 2);
        assert_eq!(profile.listening_history[0].track.title, "First");
        assert_eq!(profile.listening_history[1].track.title, "Second");
    }

    #[test]
    fn rejects_non_https_profile_artwork_and_deduplicates_tracks() {
        let json = r#"{"raptor_music_profile":{"avatar_url":"http://example/avatar.png","saved_tracks":[
          {"title":"Same","artist":"Artist"},{"title":"Same","artist":"Artist"}
        ]}}"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.avatar_url, None);
        assert_eq!(profile.saved_tracks.len(), 1);
    }

    #[test]
    fn merges_multiple_export_documents_without_duplicate_tracks_or_artists() {
        let first = parse_profile_export(r#"{"playlists":[{"name":"Mix","tracks":[
          {"source_id":"track-1","title":"One","artist":"A"}
        ]}]}"#).unwrap();
        let second = parse_profile_export(r#"{"tracks":[
          {"track":{"trackName":"Two","artistName":"B","trackUri":"track-2"}}
        ]}"#).unwrap();
        let mut combined = first;
        combined.merge(second);
        assert_eq!(combined.playlists.len(), 1);
        assert_eq!(combined.playlists[0].tracks.len(), 1);
        assert_eq!(combined.saved_tracks.len(), 1);
        assert_eq!(combined.saved_tracks[0].title, "Two");
    }


    #[test]
    fn parses_spotify_extended_streaming_history_array() {
        let json = r#"[
          {"ts":"2026-10-01T12:00:00Z","ms_played":183000,
           "master_metadata_track_name":"Independent Track",
           "master_metadata_album_artist_name":"Small Artist",
           "master_metadata_album_album_name":"First EP",
           "spotify_track_uri":"spotify:track:abc"},
          {"ts":"2026-10-01T12:05:00Z","ms_played":90000,
           "master_metadata_track_name":"Another Track",
           "master_metadata_album_artist_name":"Another Artist",
           "master_metadata_album_album_name":null},
          {"ts":"2026-10-01T12:08:00Z","ms_played":45000,
           "episode_name":"Podcast episode"}
        ]"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.source, "Spotify extended listening history");
        assert_eq!(profile.listening_history.len(), 2);
        assert_eq!(profile.listening_history[0].track.title, "Independent Track");
        assert_eq!(profile.listening_history[0].track.artist, "Small Artist");
        assert_eq!(profile.listening_history[0].ms_played, Some(183000));
        assert_eq!(profile.listening_history[0].played_at.as_deref(), Some("2026-10-01T12:00:00Z"));
        assert_eq!(profile.listening_history[1].track.title, "Another Track");
        assert_eq!(profile.listening_history[1].track.album, None);
    }

    #[test]
    fn parses_legacy_spotify_streaming_history_camel_case_export() {
        let json = r#"[
          {"endTime":"2021-05-02 13:45","msPlayed":212000,
           "trackName":"Basement Track","artistName":"Underground Artist",
           "albumName":"Demo EP","trackURI":"spotify:track:legacy"},
          {"endTime":"2021-05-02 13:50","msPlayed":80000,
           "trackName":"Second Track","artistName":"Another Artist",
           "albumName":"","trackURI":"spotify:track:legacy-2"},
          {"endTime":"2021-05-02 13:55","msPlayed":1000,
           "episodeName":"Podcast"}
        ]"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.listening_history.len(), 2);
        let first = &profile.listening_history[0];
        assert_eq!(first.track.title, "Basement Track");
        assert_eq!(first.track.artist, "Underground Artist");
        assert_eq!(first.track.album.as_deref(), Some("Demo EP"));
        assert_eq!(first.track.source_id.as_deref(), Some("spotify:track:legacy"));
        assert_eq!(first.played_at.as_deref(), Some("2021-05-02 13:45"));
        assert_eq!(first.ms_played, Some(212000));
    }

    #[test]
    fn skips_non_music_rows_in_spotify_history() {
        let json = r#"[{"ts":"2026-10-01T12:00:00Z","ms_played":1000,"episode_name":"Podcast"}]"#;
        let profile = parse_profile_export(json).unwrap();
        assert!(profile.listening_history.is_empty());
    }

    #[test]
    fn rejects_unrecognized_exports_with_actionable_error() {
        assert!(parse_profile_export(r#"{"unrelated":true}"#).unwrap_err().contains("Unsupported export"));
    }
}
