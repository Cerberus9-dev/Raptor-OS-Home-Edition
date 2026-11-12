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
        if !url.starts_with("https://") || !url.contains("bandcamp.com/") {
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
