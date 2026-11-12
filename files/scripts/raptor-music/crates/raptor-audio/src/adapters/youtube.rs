use reqwest::blocking::Client;
use raptor_core::models::{
    AudioSourceKind, PlaybackAccess, PlaybackTarget, ProviderTrackRecord, UnifiedTrack,
};
use serde_json::Value;
use std::time::Duration;

use crate::backend::{AudioSource, PlaybackError, ResolvedPlayback};

/// YouTube Data API adapter. Search returns video metadata and an embedded
/// player target; it does not extract media URLs or turn videos into streams.
pub struct YouTubeAdapter {
    client: Client,
    api_key: String,
}

impl YouTubeAdapter {
    pub fn new(api_key: impl Into<String>) -> Result<Self, PlaybackError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(15))
            .user_agent(concat!("RaptorMusic/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?;
        Ok(Self { client, api_key: api_key.into() })
    }

    fn parse_video(item: &Value) -> Option<UnifiedTrack> {
        let id = item.pointer("/id/videoId")?.as_str()?.trim();
        if id.is_empty() { return None; }

        let snippet = item.get("snippet")?;
        let title = snippet.get("title")?.as_str()?.to_owned();
        let channel = snippet.get("channelTitle").and_then(Value::as_str)
            .unwrap_or("Unknown channel").to_owned();
        let thumbnail = snippet.pointer("/thumbnails/high/url")
            .or_else(|| snippet.pointer("/thumbnails/medium/url"))
            .or_else(|| snippet.pointer("/thumbnails/default/url"))
            .and_then(Value::as_str).map(str::to_owned);

        let record = ProviderTrackRecord {
            source: AudioSourceKind::YouTube,
            source_track_id: id.to_owned(),
            title,
            artists: vec![channel],
            album: None,
            artwork_url: thumbnail,
            // Search.list does not return duration. A separate videos.list
            // request can be added if the UI needs that metadata.
            duration_secs: None,
            isrc: None,
        };
        Some(UnifiedTrack::from_provider(
            record,
            PlaybackAccess::EmbeddedPlayer,
            PlaybackTarget::EmbeddedPlayer {
                provider_id: "youtube".into(),
                content_id: id.to_owned(),
            },
        ))
    }
}

impl AudioSource for YouTubeAdapter {
    fn source_kind(&self) -> AudioSourceKind { AudioSourceKind::YouTube }

    fn search(&self, query: &str) -> Result<Vec<UnifiedTrack>, PlaybackError> {
        if query.trim().is_empty() { return Ok(Vec::new()); }

        let response = self.client
            .get("https://www.googleapis.com/youtube/v3/search")
            .query(&[
                ("part", "snippet"),
                ("type", "video"),
                ("maxResults", "50"),
                ("q", query.trim()),
                ("key", self.api_key.as_str()),
            ])
            .send()
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?
            .error_for_status()
            .map_err(|error| PlaybackError::SourceResolution(format!("YouTube Data API: {error}")))?;

        let payload: Value = response.json()
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?;
        let items = payload.get("items").and_then(Value::as_array)
            .ok_or_else(|| PlaybackError::SourceResolution(
                "YouTube search response did not contain items".into()
            ))?;
        Ok(items.iter().filter_map(Self::parse_video).collect())
    }

    fn resolve(&self, track: &UnifiedTrack) -> Result<ResolvedPlayback, PlaybackError> {
        if track.source != AudioSourceKind::YouTube {
            return Err(PlaybackError::SourceResolution("YouTube adapter received a non-YouTube track".into()));
        }
        if track.source_track_id.trim().is_empty() {
            return Err(PlaybackError::EmptyUri);
        }
        Ok(ResolvedPlayback {
            uri: format!("https://www.youtube.com/watch?v={}", track.source_track_id),
            access: PlaybackAccess::EmbeddedPlayer,
            engine_source: raptor_core::models::PlaybackSource::Unknown {
                raw_type: "youtube-embedded-player".into(),
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn youtube_search_record_is_an_embedded_target_not_a_direct_stream() {
        let track = YouTubeAdapter::parse_video(&serde_json::json!({
            "id": {"videoId": "youtube-video-id"},
            "snippet": {
                "title": "Night Drive",
                "channelTitle": "Independent Artist",
                "thumbnails": {"high": {"url": "https://images.example.test/video.jpg"}}
            }
        })).expect("valid YouTube video");

        assert_eq!(track.source, AudioSourceKind::YouTube);
        assert_eq!(track.source_track_id, "youtube-video-id");
        assert_eq!(track.access, PlaybackAccess::EmbeddedPlayer);
        assert!(matches!(track.target, PlaybackTarget::EmbeddedPlayer { .. }));
    }
}
