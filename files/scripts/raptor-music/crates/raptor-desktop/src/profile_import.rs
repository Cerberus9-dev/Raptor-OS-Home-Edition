//! Normalized, privacy-conscious profile migration model.
//!
//! This module deliberately parses exported data rather than scraping source
//! services. Provider adapters can normalize their official export/API payloads
//! into this model before the library persists the import.

use serde_json::Value;
use std::collections::HashSet;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ImportedProfile {
    pub source: String,
    pub display_name: Option<String>,
    pub username: Option<String>,
    pub biography: Option<String>,
    pub avatar_url: Option<String>,
    pub playlists: Vec<ImportedPlaylist>,
    pub saved_tracks: Vec<ImportedTrack>,
    pub followed_artists: Vec<ImportedArtist>,
    pub listening_history: Vec<ImportedListen>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ImportedPlaylist {
    pub source_id: Option<String>,
    pub name: String,
    pub description: Option<String>,
    pub artwork_url: Option<String>,
    pub tracks: Vec<ImportedTrack>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct ImportedTrack {
    pub source_id: Option<String>,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportedArtist {
    pub source_id: Option<String>,
    pub name: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportedListen {
    pub track: ImportedTrack,
    pub played_at: Option<String>,
    pub play_count: u32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ImportSummary {
    pub playlists: usize,
    pub playlist_tracks: usize,
    pub saved_tracks: usize,
    pub followed_artists: usize,
    pub listening_events: usize,
    pub has_profile_image: bool,
}

pub fn parse_profile_export(payload: &str) -> Result<ImportedProfile, String> {
    let root: Value = serde_json::from_str(payload)
        .map_err(|_| "The selected file is not valid JSON".to_string())?;

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
    if let Some(rows) = value.get("listening_history").and_then(Value::as_array) {
        profile.listening_history = rows.iter().filter_map(|row| {
            let track = parse_normalized_track(row)?;
            Some(ImportedListen {
                track,
                played_at: string(row, "played_at"),
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
        let tracks = row.get("items").and_then(Value::as_array)
            .map(|items| items.iter().filter_map(|item| {
                let track = item.get("track").unwrap_or(item);
                parse_spotify_track(track)
            }).collect())
            .unwrap_or_default();
        profile.playlists.push(ImportedPlaylist {
            source_id: string(row, "uri"),
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
    value.filter(|url| url.starts_with("https://") && !url.chars().any(char::is_control))
}

fn deduplicate_profile(profile: &mut ImportedProfile) {
    for playlist in &mut profile.playlists {
        deduplicate_tracks(&mut playlist.tracks);
    }
    deduplicate_tracks(&mut profile.saved_tracks);
    let mut artists = HashSet::new();
    profile.followed_artists.retain(|artist| artists.insert(artist.name.to_lowercase()));
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
    pub fn summary(&self) -> ImportSummary {
        ImportSummary {
            playlists: self.playlists.len(),
            playlist_tracks: self.playlists.iter().map(|p| p.tracks.len()).sum(),
            saved_tracks: self.saved_tracks.len(),
            followed_artists: self.followed_artists.len(),
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
            followed_artists: 1, listening_events: 1, has_profile_image: true,
        });
        assert_eq!(profile.listening_history[0].play_count, 3);
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
    fn rejects_non_https_profile_artwork_and_deduplicates_tracks() {
        let json = r#"{"raptor_music_profile":{"avatar_url":"http://example/avatar.png","saved_tracks":[
          {"title":"Same","artist":"Artist"},{"title":"Same","artist":"Artist"}
        ]}}"#;
        let profile = parse_profile_export(json).unwrap();
        assert_eq!(profile.avatar_url, None);
        assert_eq!(profile.saved_tracks.len(), 1);
    }

    #[test]
    fn rejects_unrecognized_exports_with_actionable_error() {
        assert!(parse_profile_export(r#"{"unrelated":true}"#).unwrap_err().contains("Unsupported export"));
    }
}
