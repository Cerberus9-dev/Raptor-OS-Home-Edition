use raptor_core::models::{AudioSourceKind, PlaybackAccess, PlaybackTarget, UnifiedTrack};

use crate::backend::{AudioSource, PlaybackError, ResolvedPlayback};

/// Bandcamp handoff adapter.
///
/// Bandcamp does not provide a general-purpose public consumer streaming API.
/// This adapter therefore supports provider URLs already attached to a
/// normalized track and leaves search/streaming unavailable until an approved
/// API or integration is available.
#[derive(Default)]
pub struct BandcampAdapter;

impl BandcampAdapter {
    pub fn new() -> Self { Self }
}

impl AudioSource for BandcampAdapter {
    fn source_kind(&self) -> AudioSourceKind { AudioSourceKind::Bandcamp }

    fn resolve(&self, track: &UnifiedTrack) -> Result<ResolvedPlayback, PlaybackError> {
        if track.source != AudioSourceKind::Bandcamp {
            return Err(PlaybackError::SourceResolution("Bandcamp adapter received a non-Bandcamp track".into()));
        }
        let url = match &track.target {
            PlaybackTarget::ExternalHandoff { url } => url.clone(),
            _ => return Err(PlaybackError::UnsupportedAccess),
        };
        let parsed = reqwest::Url::parse(&url).map_err(|error| PlaybackError::SourceResolution(error.to_string()))?;
        let host = parsed.host_str().unwrap_or_default();
        if parsed.scheme() != "https"
            || !(host == "bandcamp.com" || host.ends_with(".bandcamp.com"))
        {
            return Err(PlaybackError::SourceResolution(
                "Bandcamp handoff must be an HTTPS Bandcamp URL".into()
            ));
        }
        Ok(ResolvedPlayback {
            uri: url,
            access: PlaybackAccess::ExternalHandoff,
            engine_source: raptor_core::models::PlaybackSource::Unknown {
                raw_type: "bandcamp-official-handoff".into(),
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use raptor_core::models::ProviderTrackRecord;

    fn track(url: &str) -> UnifiedTrack {
        UnifiedTrack::from_provider(
            ProviderTrackRecord {
                source: AudioSourceKind::Bandcamp,
                source_track_id: "track-id".into(),
                title: "Track".into(),
                artists: vec!["Artist".into()],
                album: None,
                artwork_url: None,
                duration_secs: None,
                isrc: None,
            },
            PlaybackAccess::ExternalHandoff,
            PlaybackTarget::ExternalHandoff { url: url.into() },
        )
    }

    #[test]
    fn accepts_https_bandcamp_handoff() {
        let resolved = BandcampAdapter::new().resolve(&track(
            "https://artist.bandcamp.com/track/example"
        )).unwrap();
        assert_eq!(resolved.access, PlaybackAccess::ExternalHandoff);
    }

    #[test]
    fn rejects_spoofed_bandcamp_host() {
        assert!(BandcampAdapter::new().resolve(&track(
            "https://bandcamp.com.attacker.example/track/example"
        )).is_err());
    }
}
