//! Provider response adapters.
//!
//! Real wrapper clients should deserialize their responses into these narrow
//! DTOs, then convert to ProviderTrackRecord. The desktop UI never consumes
//! provider-specific response objects.

use crate::models::{
    AudioSourceKind, ProviderTrackRecord, UnifiedTrack, PlaybackAccess, PlaybackTarget,
};

#[derive(Debug, Clone)]
pub struct SpotifyTrackData {
    pub id: String,
    pub name: String,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub artwork_url: Option<String>,
    pub duration_ms: Option<u64>,
    pub isrc: Option<String>,
}

impl From<SpotifyTrackData> for ProviderTrackRecord {
    fn from(track: SpotifyTrackData) -> Self {
        Self {
            source: AudioSourceKind::Spotify,
            source_track_id: track.id,
            title: track.name,
            artists: track.artists,
            album: track.album,
            artwork_url: track.artwork_url,
            duration_secs: track.duration_ms.map(|ms| ms / 1_000),
            isrc: track.isrc,
        }
    }
}

#[derive(Debug, Clone)]
pub struct YouTubeTrackData {
    pub video_id: String,
    pub title: String,
    pub channel_title: String,
    pub thumbnail_url: Option<String>,
    pub duration_secs: Option<u64>,
}

impl From<YouTubeTrackData> for ProviderTrackRecord {
    fn from(track: YouTubeTrackData) -> Self {
        Self {
            source: AudioSourceKind::YouTube,
            source_track_id: track.video_id,
            title: track.title,
            artists: vec![track.channel_title],
            album: None,
            artwork_url: track.thumbnail_url,
            duration_secs: track.duration_secs,
            isrc: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct BandcampTrackData {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub artwork_url: Option<String>,
    pub duration_secs: Option<u64>,
    pub isrc: Option<String>,
}

impl From<BandcampTrackData> for ProviderTrackRecord {
    fn from(track: BandcampTrackData) -> Self {
        Self {
            source: AudioSourceKind::Bandcamp,
            source_track_id: track.id,
            title: track.title,
            artists: vec![track.artist],
            album: track.album,
            artwork_url: track.artwork_url,
            duration_secs: track.duration_secs,
            isrc: track.isrc,
        }
    }
}

/// Final adapter step: provider metadata plus an explicitly resolved playback
/// permission/target becomes the only track shape exposed to Raptor.
pub fn normalize_provider_track(
    record: impl Into<ProviderTrackRecord>,
    access: PlaybackAccess,
    target: PlaybackTarget,
) -> UnifiedTrack {
    UnifiedTrack::from_provider(record.into(), access, target)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spotify_duration_is_normalized_from_milliseconds() {
        let record = SpotifyTrackData {
            id: "spotify-id".into(),
            name: "Track".into(),
            artists: vec!["Artist".into()],
            album: Some("Album".into()),
            artwork_url: None,
            duration_ms: Some(183_500),
            isrc: Some("USABC2600001".into()),
        };
        let unified = normalize_provider_track(
            record,
            PlaybackAccess::ExternalHandoff,
            PlaybackTarget::ExternalHandoff {
                url: "https://open.spotify.com/track/spotify-id".into(),
            },
        );
        assert_eq!(unified.source, AudioSourceKind::Spotify);
        assert_eq!(unified.duration_secs, Some(183));
        assert_eq!(unified.access, PlaybackAccess::ExternalHandoff);
    }

    #[test]
    fn youtube_video_metadata_stays_an_embedded_player_target() {
        let record = YouTubeTrackData {
            video_id: "video-id".into(),
            title: "Track".into(),
            channel_title: "Artist".into(),
            thumbnail_url: None,
            duration_secs: Some(200),
        };
        let unified = normalize_provider_track(
            record,
            PlaybackAccess::EmbeddedPlayer,
            PlaybackTarget::EmbeddedPlayer {
                provider_id: "youtube".into(),
                content_id: "video-id".into(),
            },
        );
        assert_eq!(unified.source, AudioSourceKind::YouTube);
        assert_eq!(unified.access, PlaybackAccess::EmbeddedPlayer);
    }

    #[test]
    fn bandcamp_metadata_can_map_to_a_direct_stream_when_authorized() {
        let record = BandcampTrackData {
            id: "bandcamp-id".into(),
            title: "Track".into(),
            artist: "Artist".into(),
            album: Some("Album".into()),
            artwork_url: None,
            duration_secs: Some(190),
            isrc: None,
        };
        let unified = normalize_provider_track(
            record,
            PlaybackAccess::DirectStream,
            PlaybackTarget::Native(
                crate::models::PlaybackSource::RemoteStream {
                    provider_id: "bandcamp".into(),
                    provider_track_id: "bandcamp-id".into(),
                },
            ),
        );
        assert_eq!(unified.source, AudioSourceKind::Bandcamp);
        assert_eq!(unified.source_track_id, "bandcamp-id");
    }
}
