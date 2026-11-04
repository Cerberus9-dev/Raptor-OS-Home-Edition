use uuid::Uuid;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlaybackSource {
    LocalFile { path: PathBuf },
    RemoteStream { provider_id: String, provider_track_id: String },
    Unknown { raw_type: String },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Track {
    pub id: Uuid,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_secs: Option<u64>,
    pub source: PlaybackSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayerState {
    Idle,
    Loading,
    Playing,
    Paused,
    Buffering,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PlayerEvent {
    SessionStarted { session_token: Uuid, track_id: Uuid, queue_entry_id: Uuid },
    Paused { session_token: Uuid },
    Resumed { session_token: Uuid },
    Stopped { session_token: Uuid },
    PlaybackFailed { session_token: Uuid, error_message: String },
    NaturalEof { session_token: Uuid, queue_entry_id: Uuid },
    SessionTerminated { session_token: Uuid },
}
