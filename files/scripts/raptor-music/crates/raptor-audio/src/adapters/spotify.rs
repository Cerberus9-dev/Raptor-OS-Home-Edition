use reqwest::blocking::Client;
use raptor_core::models::{
    AudioSourceKind, PlaybackAccess, PlaybackTarget, ProviderTrackRecord, UnifiedTrack,
};
use serde_json::Value;
use std::time::Duration;

use crate::backend::{AudioSource, PlaybackError, ResolvedPlayback};

/// Spotify Web API adapter.
///
/// This adapter deliberately exposes metadata search plus an official Spotify
/// track handoff. Spotify Web API access does not grant an audio stream, so it
/// never fabricates a DirectStream target.
pub struct SpotifyAdapter {
    client: Client,
    access_token: String,
}

impl SpotifyAdapter {
    pub fn new(access_token: impl Into<String>) -> Result<Self, PlaybackError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(15))
            .user_agent(concat!("RaptorMusic/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?;
        Ok(Self { client, access_token: access_token.into() })
    }

    fn parse_track(item: &Value) -> Option<UnifiedTrack> {
        let id = item.get("id")?.as_str()?.trim();
        if id.is_empty() { return None; }

        let artists = item.get("artists")?.as_array()?
            .iter()
            .filter_map(|artist| artist.get("name").and_then(Value::as_str))
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let title = item.get("name")?.as_str()?.to_owned();
        let album = item.pointer("/album/name").and_then(Value::as_str).map(str::to_owned);
        let artwork_url = item.pointer("/album/images/0/url")
            .and_then(Value::as_str).map(str::to_owned);
        let duration_ms = item.get("duration_ms").and_then(Value::as_u64);
        let isrc = item.pointer("/external_ids/isrc").and_then(Value::as_str).map(str::to_owned);

        let record = ProviderTrackRecord {
            source: AudioSourceKind::Spotify,
            source_track_id: id.to_owned(),
            title,
            artists,
            album,
            artwork_url,
            duration_secs: duration_ms.map(|value| value / 1_000),
            isrc,
        };
        let handoff = format!("https://open.spotify.com/track/{id}");
        Some(UnifiedTrack::from_provider(
            record,
            PlaybackAccess::ExternalHandoff,
            PlaybackTarget::ExternalHandoff { url: handoff },
        ))
    }
}

impl AudioSource for SpotifyAdapter {
    fn source_kind(&self) -> AudioSourceKind { AudioSourceKind::Spotify }

    fn search(&self, query: &str) -> Result<Vec<UnifiedTrack>, PlaybackError> {
        if query.trim().is_empty() { return Ok(Vec::new()); }

        let response = self.client
            .get("https://api.spotify.com/v1/search")
            .bearer_auth(&self.access_token)
            .query(&[("q", query.trim()), ("type", "track"), ("limit", "50")])
            .send()
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?
            .error_for_status()
            .map_err(|error| PlaybackError::SourceResolution(format!("Spotify API: {error}")))?;

        let payload: Value = response.json()
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?;
        let items = payload.pointer("/tracks/items")
            .and_then(Value::as_array)
            .ok_or_else(|| PlaybackError::SourceResolution(
                "Spotify search response did not contain tracks.items".into()
            ))?;

        Ok(items.iter().filter_map(Self::parse_track).collect())
    }

    fn resolve(&self, track: &UnifiedTrack) -> Result<ResolvedPlayback, PlaybackError> {
        if track.source != AudioSourceKind::Spotify {
            return Err(PlaybackError::SourceResolution("Spotify adapter received a non-Spotify track".into()));
        }
        let url = match &track.target {
            PlaybackTarget::ExternalHandoff { url } => url.clone(),
            _ => format!("https://open.spotify.com/track/{}", track.source_track_id),
        };
        Ok(ResolvedPlayback {
            uri: url,
            access: PlaybackAccess::ExternalHandoff,
            engine_source: raptor_core::models::PlaybackSource::Unknown {
                raw_type: "spotify-official-handoff".into(),
            },
        })
    }
}
