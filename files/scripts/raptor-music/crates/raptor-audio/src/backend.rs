use raptor_core::models::{
    AudioSourceKind, PlaybackAccess, PlaybackSource as EnginePlaybackSource,
    PlayerState, UnifiedTrack,
};
use std::time::Duration;
use uuid::Uuid;

use crate::player::AudioPlayer;

/// A provider adapter resolves a normalized track into an authorized playback
/// target. The URI is descriptive; engine_source is the typed input accepted
/// by Raptor's current audio engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedPlayback {
    pub uri: String,
    pub access: PlaybackAccess,
    pub engine_source: EnginePlaybackSource,
}

/// The provider-neutral playback request passed from RaptorPlayer to a backend.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaybackSource {
    pub track_id: Uuid,
    pub uri: String,
    pub access: PlaybackAccess,
    pub engine_source: EnginePlaybackSource,
}

#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum PlaybackError {
    #[error("No playback adapter is registered for {0:?}")]
    MissingSourceAdapter(AudioSourceKind),
    #[error("This track is unavailable from its provider")]
    Unavailable,
    #[error("This provider requires an embedded player or external handoff")]
    UnsupportedAccess,
    #[error("The provider could not resolve playback: {0}")]
    SourceResolution(String),
    #[error("The audio backend could not load the track: {0}")]
    Backend(String),
    #[error("The provider returned an empty playback URI")]
    EmptyUri,
    #[error("Search is not supported by this provider adapter")]
    SearchUnsupported,
    #[error("The selected backend cannot host an embedded provider player")]
    EmbeddedUnsupported,
    #[error("The selected backend cannot open an external provider handoff")]
    HandoffUnsupported,
}

/// Implement once per provider wrapper. Wrapper-specific response types stay
/// inside the adapter and never cross into the UI or playback queue.
pub trait AudioSource: Send + Sync {
    fn source_kind(&self) -> AudioSourceKind;

    fn provider_id(&self) -> &'static str {
        match self.source_kind() {
            AudioSourceKind::Spotify => "spotify",
            AudioSourceKind::YouTube => "youtube",
            AudioSourceKind::Bandcamp => "bandcamp",
            AudioSourceKind::Local => "local",
        }
    }

    /// Search through the provider's supported API or wrapper interface.
    /// Provider response objects must be normalized before they leave the adapter.
    fn search(&self, _query: &str) -> Result<Vec<UnifiedTrack>, PlaybackError> {
        Err(PlaybackError::SearchUnsupported)
    }

    /// Resolve availability and the provider-approved playback mode.
    fn resolve(&self, track: &UnifiedTrack) -> Result<ResolvedPlayback, PlaybackError>;

    /// Resolve an authorized direct/preview stream. Embedded and handoff
    /// providers should not expose their media URLs through this method.
    fn stream(&self, track: &UnifiedTrack) -> Result<ResolvedPlayback, PlaybackError> {
        self.resolve(track)
    }
}

/// Common playback contract. UI and queue code depend on this trait rather
/// than CPAL, Rodio, mpv, codecs, or provider wrapper types.
pub trait AudioBackend: Send {
    fn load(&mut self, source: &PlaybackSource) -> Result<(), PlaybackError>;

    fn open_embedded(&mut self, _provider_id: &str, _content_id: &str) -> Result<(), PlaybackError> {
        Err(PlaybackError::EmbeddedUnsupported)
    }

    fn handoff(&mut self, _url: &str) -> Result<(), PlaybackError> {
        Err(PlaybackError::HandoffUnsupported)
    }

    fn play(&mut self) -> Result<(), PlaybackError>;
    fn pause(&mut self) -> Result<(), PlaybackError>;
    fn stop(&mut self) -> Result<(), PlaybackError>;
    fn seek(&mut self, position: Duration) -> Result<(), PlaybackError>;
    fn position(&self) -> Duration;
    fn state(&self) -> PlayerState;
}

/// Adapter for Raptor's existing CPAL-backed player. Future mpv/Rodio
/// implementations can satisfy the same contract without changing routing.
pub struct CpalBackend {
    player: AudioPlayer,
    session_token: Option<Uuid>,
}

impl CpalBackend {
    pub fn new() -> Self {
        Self {
            player: AudioPlayer::new(),
            session_token: None,
        }
    }

    fn active_session(&self) -> Result<Uuid, PlaybackError> {
        self.session_token.ok_or_else(|| {
            PlaybackError::Backend("No track is loaded".into())
        })
    }
}

impl Default for CpalBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioBackend for CpalBackend {
    fn load(&mut self, source: &PlaybackSource) -> Result<(), PlaybackError> {
        match source.access {
            PlaybackAccess::Unavailable => return Err(PlaybackError::Unavailable),
            PlaybackAccess::EmbeddedPlayer | PlaybackAccess::ExternalHandoff => {
                return Err(PlaybackError::UnsupportedAccess);
            }
            PlaybackAccess::DirectStream | PlaybackAccess::PreviewOnly => {}
        }
        if source.uri.trim().is_empty() {
            return Err(PlaybackError::EmptyUri);
        }

        let session = Uuid::new_v4();
        self.player
            .play(
                source.engine_source.clone(),
                source.track_id,
                Uuid::new_v4(),
                session,
            )
            .map_err(PlaybackError::Backend)?;
        self.session_token = Some(session);
        Ok(())
    }

    fn play(&mut self) -> Result<(), PlaybackError> {
        self.player.resume(self.active_session()?);
        Ok(())
    }

    fn pause(&mut self) -> Result<(), PlaybackError> {
        self.player.pause(self.active_session()?);
        Ok(())
    }

    fn stop(&mut self) -> Result<(), PlaybackError> {
        self.player.stop(self.active_session()?);
        self.session_token = None;
        Ok(())
    }

    fn seek(&mut self, position: Duration) -> Result<(), PlaybackError> {
        self.player
            .seek(position.as_secs_f64(), self.active_session()?);
        Ok(())
    }

    fn position(&self) -> Duration {
        Duration::from_secs(self.player.get_position_secs())
    }

    fn state(&self) -> PlayerState {
        self.player.get_state()
    }
}

/// Routes normalized tracks through the matching provider adapter and then
/// delegates playback/control to the selected audio backend.
pub struct RaptorPlayer {
    backend: Box<dyn AudioBackend>,
    sources: Vec<Box<dyn AudioSource>>,
}

impl RaptorPlayer {
    pub fn new(
        backend: Box<dyn AudioBackend>,
        sources: Vec<Box<dyn AudioSource>>,
    ) -> Self {
        Self { backend, sources }
    }

    pub fn play_track(&mut self, track: &UnifiedTrack) -> Result<(), PlaybackError> {
        if track.access == PlaybackAccess::Unavailable {
            return Err(PlaybackError::Unavailable);
        }

        let source = self.sources
            .iter()
            .find(|source| source.source_kind() == track.source)
            .ok_or(PlaybackError::MissingSourceAdapter(track.source))?;

        let resolved = source.resolve(track)?;
        if resolved.access == PlaybackAccess::Unavailable {
            return Err(PlaybackError::Unavailable);
        }

        match resolved.access {
            PlaybackAccess::DirectStream | PlaybackAccess::PreviewOnly => {
                let stream = source.stream(track)?;
                if stream.access == PlaybackAccess::Unavailable {
                    return Err(PlaybackError::Unavailable);
                }
                if stream.uri.trim().is_empty() {
                    return Err(PlaybackError::EmptyUri);
                }
                let playback_source = PlaybackSource {
                    track_id: track.id,
                    uri: stream.uri,
                    access: stream.access,
                    engine_source: stream.engine_source,
                };
                self.backend.load(&playback_source)
            }
            PlaybackAccess::EmbeddedPlayer => {
                let content_id = track.source_track_id.as_str();
                if content_id.trim().is_empty() {
                    return Err(PlaybackError::EmptyUri);
                }
                self.backend.open_embedded(source.provider_id(), content_id)
            }
            PlaybackAccess::ExternalHandoff => {
                if resolved.uri.trim().is_empty() {
                    return Err(PlaybackError::EmptyUri);
                }
                self.backend.handoff(&resolved.uri)
            }
            PlaybackAccess::Unavailable => Err(PlaybackError::Unavailable),
        }
    }

    pub fn play(&mut self) -> Result<(), PlaybackError> {
        self.backend.play()
    }

    pub fn pause(&mut self) -> Result<(), PlaybackError> {
        self.backend.pause()
    }

    pub fn stop(&mut self) -> Result<(), PlaybackError> {
        self.backend.stop()
    }

    pub fn seek(&mut self, position: Duration) -> Result<(), PlaybackError> {
        self.backend.seek(position)
    }

    /// PlayerState is the engine's authoritative playing/paused/error status.
    /// Position is queried separately through position() to keep the existing
    /// PlayerState enum stable for current UI consumers.
    pub fn get_state(&self) -> PlayerState {
        self.backend.state()
    }

    pub fn position(&self) -> Duration {
        self.backend.position()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    struct FakeSource {
        kind: AudioSourceKind,
        result: Result<ResolvedPlayback, PlaybackError>,
    }

    impl AudioSource for FakeSource {
        fn source_kind(&self) -> AudioSourceKind {
            self.kind
        }

        fn resolve(&self, _track: &UnifiedTrack) -> Result<ResolvedPlayback, PlaybackError> {
            self.result.clone()
        }
    }

    #[derive(Default)]
    struct FakeBackend {
        loaded: Arc<Mutex<Option<PlaybackSource>>>,
    }

    impl AudioBackend for FakeBackend {
        fn load(&mut self, source: &PlaybackSource) -> Result<(), PlaybackError> {
            *self.loaded.lock().unwrap() = Some(source.clone());
            Ok(())
        }
        fn play(&mut self) -> Result<(), PlaybackError> { Ok(()) }
        fn pause(&mut self) -> Result<(), PlaybackError> { Ok(()) }
        fn stop(&mut self) -> Result<(), PlaybackError> { Ok(()) }
        fn seek(&mut self, _position: Duration) -> Result<(), PlaybackError> { Ok(()) }
        fn position(&self) -> Duration { Duration::from_secs(12) }
        fn state(&self) -> PlayerState { PlayerState::Playing }
    }

    fn track(source: AudioSourceKind, access: PlaybackAccess) -> UnifiedTrack {
        UnifiedTrack {
            id: Uuid::new_v4(),
            source,
            source_track_id: "provider-track".into(),
            title: "Test track".into(),
            artists: vec!["Test artist".into()],
            album: None,
            artwork_url: None,
            duration_secs: Some(180),
            isrc: None,
            access,
            target: raptor_core::models::PlaybackTarget::Unavailable,
        }
    }

    #[test]
    fn routes_track_to_matching_adapter_and_backend() {
        let resolved = ResolvedPlayback {
            uri: "https://audio.example.test/track".into(),
            access: PlaybackAccess::DirectStream,
            engine_source: EnginePlaybackSource::RemoteStream {
                provider_id: "audius".into(),
                provider_track_id: "provider-track".into(),
            },
        };
        let backend = FakeBackend::default();
        let loaded = Arc::clone(&backend.loaded);
        let mut player = RaptorPlayer::new(
            Box::new(backend),
            vec![Box::new(FakeSource {
                kind: AudioSourceKind::Spotify,
                result: Ok(resolved),
            })],
        );
        let track = track(AudioSourceKind::Spotify, PlaybackAccess::DirectStream);

        player.play_track(&track).unwrap();

        let request = loaded.lock().unwrap().clone().unwrap();
        assert_eq!(request.track_id, track.id);
        assert_eq!(request.uri, "https://audio.example.test/track");
        assert_eq!(request.access, PlaybackAccess::DirectStream);
    }

    #[test]
    fn unavailable_track_returns_specific_error_without_loading_backend() {
        let backend = FakeBackend::default();
        let loaded = Arc::clone(&backend.loaded);
        let mut player = RaptorPlayer::new(
            Box::new(backend),
            vec![Box::new(FakeSource {
                kind: AudioSourceKind::Bandcamp,
                result: Err(PlaybackError::Unavailable),
            })],
        );
        let track = track(AudioSourceKind::Bandcamp, PlaybackAccess::Unavailable);

        assert_eq!(player.play_track(&track), Err(PlaybackError::Unavailable));
        assert!(loaded.lock().unwrap().is_none());
    }

    #[test]
    fn missing_provider_adapter_is_reported() {
        let mut player = RaptorPlayer::new(Box::<FakeBackend>::default(), vec![]);
        let track = track(AudioSourceKind::YouTube, PlaybackAccess::EmbeddedPlayer);
        assert_eq!(
            player.play_track(&track),
            Err(PlaybackError::MissingSourceAdapter(AudioSourceKind::YouTube))
        );
    }

    #[test]
    fn controls_and_state_delegate_to_backend() {
        let mut player = RaptorPlayer::new(Box::<FakeBackend>::default(), vec![]);
        player.play().unwrap();
        player.pause().unwrap();
        player.seek(Duration::from_secs(5)).unwrap();
        assert_eq!(player.position(), Duration::from_secs(12));
        assert_eq!(player.get_state(), PlayerState::Playing);
        player.stop().unwrap();
    }
}
