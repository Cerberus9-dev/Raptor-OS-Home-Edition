use reqwest::blocking::Client;
use raptor_core::models::{
    AudioSourceKind, PlaybackAccess, PlaybackTarget, ProviderTrackRecord, UnifiedTrack,
};
use serde_json::Value;
use std::time::Duration;

use crate::backend::{AudioSource, PlaybackError, ResolvedPlayback};

const SEARCH_ENDPOINT: &str =
    "https://bandcamp.com/api/bcsearch_public_api/1/autocomplete_elastic";

/// Bandcamp's public search adapter.
///
/// Bandcamp does not publish a general-purpose consumer catalogue API. Search
/// uses the same unauthenticated autocomplete endpoint used by its website.
/// Playback is provided by Bandcamp's official embedded player; this adapter
/// never extracts private media URLs or bypasses purchase/streaming controls.
pub struct BandcampAdapter {
    client: Client,
}

impl BandcampAdapter {
    pub fn new() -> Result<Self, PlaybackError> {
        let client = Client::builder()
            .timeout(Duration::from_secs(15))
            .user_agent(concat!("RaptorMusic/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?;
        Ok(Self { client })
    }

    fn result_id(item: &Value) -> Option<String> {
        item.get("item_id")
            .or_else(|| item.get("id"))
            .and_then(|value| {
                value.as_str().map(str::to_owned)
                    .or_else(|| value.as_u64().map(|number| number.to_string()))
            })
            .filter(|value| !value.trim().is_empty() && value.chars().all(|ch| ch.is_ascii_digit()))
    }

    fn parse_track(item: &Value) -> Option<UnifiedTrack> {
        if item.get("type").and_then(Value::as_str).is_some_and(|kind| kind != "t") {
            return None;
        }
        let id = Self::result_id(item)?;
        let title = item.get("name").and_then(Value::as_str)?.trim();
        let artist = item.get("band_name").and_then(Value::as_str)
            .or_else(|| item.get("artist").and_then(Value::as_str))?
            .trim();
        if title.is_empty() || artist.is_empty() {
            return None;
        }

        let artwork_url = item.get("img")
            .or_else(|| item.get("image_url"))
            .or_else(|| item.get("artwork_url"))
            .and_then(Value::as_str)
            .filter(|url| url.starts_with("https://"))
            .map(str::to_owned);

        let embed_url = Self::embed_url(&id);
        Some(UnifiedTrack::from_provider(
            ProviderTrackRecord {
                source: AudioSourceKind::Bandcamp,
                source_track_id: id,
                title: title.to_owned(),
                artists: vec![artist.to_owned()],
                album: None,
                artwork_url,
                duration_secs: None,
                isrc: None,
            },
            PlaybackAccess::EmbeddedPlayer,
            PlaybackTarget::EmbeddedPlayer {
                provider_id: "bandcamp".into(),
                content_id: embed_url,
            },
        ))
    }

    fn embed_url(track_id: &str) -> String {
        format!(
            "https://bandcamp.com/EmbeddedPlayer/track={track_id}/size=large/bgcol=333333/linkcol=0f91ff/tracklist=false/transparent=true/"
        )
    }

    fn parse_search_payload(payload: &Value) -> Result<Vec<UnifiedTrack>, PlaybackError> {
        let results = payload.pointer("/auto/results")
            .or_else(|| payload.get("results"))
            .and_then(Value::as_array)
            .ok_or_else(|| PlaybackError::SourceResolution(
                "Bandcamp search response did not contain a results list".into()
            ))?;
        Ok(results.iter().filter_map(Self::parse_track).collect())
    }
}

impl AudioSource for BandcampAdapter {
    fn source_kind(&self) -> AudioSourceKind { AudioSourceKind::Bandcamp }

    fn search(&self, query: &str) -> Result<Vec<UnifiedTrack>, PlaybackError> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(Vec::new());
        }

        let payload = serde_json::json!({
            "search_text": query,
            "search_filter": "t",
            "full_page": false,
            "fan_id": null
        });
        let response = self.client.post(SEARCH_ENDPOINT)
            .header(reqwest::header::ACCEPT, "application/json")
            .header(reqwest::header::REFERER, "https://bandcamp.com/")
            .json(&payload)
            .send()
            .map_err(|error| PlaybackError::SourceResolution(format!("Bandcamp search failed: {error}")))?
            .error_for_status()
            .map_err(|error| PlaybackError::SourceResolution(format!("Bandcamp search returned an error: {error}")))?;
        let body: Value = response.json()
            .map_err(|error| PlaybackError::SourceResolution(format!("Bandcamp returned unreadable search data: {error}")))?;
        Self::parse_search_payload(&body)
    }

    fn resolve(&self, track: &UnifiedTrack) -> Result<ResolvedPlayback, PlaybackError> {
        if track.source != AudioSourceKind::Bandcamp {
            return Err(PlaybackError::SourceResolution(
                "Bandcamp adapter received a non-Bandcamp track".into()
            ));
        }
        let content_id = match &track.target {
            PlaybackTarget::EmbeddedPlayer { provider_id, content_id }
                if provider_id == "bandcamp" => content_id.clone(),
            _ => Self::embed_url(&track.source_track_id),
        };
        let parsed = reqwest::Url::parse(&content_id)
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?;
        if parsed.scheme() != "https" || parsed.host_str() != Some("bandcamp.com")
            || !parsed.path().starts_with("/EmbeddedPlayer/")
        {
            return Err(PlaybackError::SourceResolution(
                "Bandcamp playback must use its official HTTPS embedded player".into()
            ));
        }
        Ok(ResolvedPlayback {
            uri: content_id.clone(),
            access: PlaybackAccess::EmbeddedPlayer,
            engine_source: raptor_core::models::PlaybackSource::Unknown {
                raw_type: "bandcamp-official-embedded-player".into(),
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bandcamp_track_search_results_into_normalized_embedded_targets() {
        let tracks = BandcampAdapter::parse_search_payload(&serde_json::json!({
            "auto": {
                "results": [{
                    "type": "t",
                    "item_id": 123456,
                    "name": "Night Drive",
                    "band_name": "Independent Artist",
                    "img": "https://f4.bcbits.com/img/a1234567890_2.jpg"
                }, {
                    "type": "a",
                    "item_id": 999,
                    "name": "Album result",
                    "band_name": "Artist"
                }]
            }
        })).expect("valid public search response");

        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].source, AudioSourceKind::Bandcamp);
        assert_eq!(tracks[0].source_track_id, "123456");
        assert_eq!(tracks[0].title, "Night Drive");
        assert_eq!(tracks[0].artists, vec!["Independent Artist"]);
        assert_eq!(tracks[0].access, PlaybackAccess::EmbeddedPlayer);
        assert!(matches!(&tracks[0].target, PlaybackTarget::EmbeddedPlayer {
            provider_id, content_id
        } if provider_id == "bandcamp" && content_id.contains("track=123456")));
    }

    #[test]
    fn rejects_non_numeric_ids_and_non_track_results() {
        let tracks = BandcampAdapter::parse_search_payload(&serde_json::json!({
            "auto": {"results": [
                {"type": "t", "item_id": "not-a-number", "name": "Bad", "band_name": "Artist"},
                {"type": "a", "item_id": 55, "name": "Album", "band_name": "Artist"}
            ]}
        })).unwrap();
        assert!(tracks.is_empty());
    }

    #[test]
    fn resolves_only_the_official_bandcamp_embedded_player() {
        let track = BandcampAdapter::parse_track(&serde_json::json!({
            "type": "t", "item_id": 42, "name": "Track", "band_name": "Artist"
        })).unwrap();
        let resolved = BandcampAdapter::new().unwrap().resolve(&track).unwrap();
        assert_eq!(resolved.access, PlaybackAccess::EmbeddedPlayer);
        assert!(resolved.uri.starts_with("https://bandcamp.com/EmbeddedPlayer/track=42/"));
    }
}
