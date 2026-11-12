use raptor_core::models::{
    PlaybackAccess, PlaybackTarget, PlayerState, UnifiedTrack,
};
use std::time::Duration;
use uuid::Uuid;

use crate::player::AudioPlayer;

/// Common playback contract. UI and queue code depend on this trait rather
/// than Rodio, mpv, CPAL, or provider wrapper types.
pub trait AudioBackend {
    fn load(&mut self, track: &UnifiedTrack) -> Result<(), String>;
    fn play(&mut self) -> Result<(), String>;
    fn pause(&mut self) -> Result<(), String>;
    fn stop(&mut self) -> Result<(), String>;
    fn seek(&mut self, position: Duration) -> Result<(), String>;
    fn position(&self) -> Duration;
    fn state(&self) -> PlayerState;
}

/// Adapter for Raptor's existing CPAL-backed player. Future mpv/Rodio
/// implementations can satisfy the same trait without changing the UI.
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

    fn active_session(&self) -> Result<Uuid, String> {
        self.session_token
            .ok_or_else(|| "No track is loaded".to_string())
    }
}

impl Default for CpalBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioBackend for CpalBackend {
    fn load(&mut self, track: &UnifiedTrack) -> Result<(), String> {
        if !matches!(
            track.access,
            PlaybackAccess::DirectStream | PlaybackAccess::PreviewOnly
        ) {
            return Err("This provider item is not available to the native audio backend".into());
        }

        let PlaybackTarget::Native(source) = &track.target else {
            return Err("This track requires its provider's embedded player or an external handoff".into());
        };

        let session = Uuid::new_v4();
        self.player.play(source.clone(), track.id, Uuid::new_v4(), session)?;
        self.session_token = Some(session);
        Ok(())
    }

    fn play(&mut self) -> Result<(), String> {
        self.player.resume(self.active_session()?);
        Ok(())
    }

    fn pause(&mut self) -> Result<(), String> {
        self.player.pause(self.active_session()?);
        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        self.player.stop(self.active_session()?);
        self.session_token = None;
        Ok(())
    }

    fn seek(&mut self, position: Duration) -> Result<(), String> {
        self.player.seek(position.as_secs_f64(), self.active_session()?);
        Ok(())
    }

    fn position(&self) -> Duration {
        Duration::from_secs(self.player.get_position_secs())
    }

    fn state(&self) -> PlayerState {
        self.player.get_state()
    }
}
