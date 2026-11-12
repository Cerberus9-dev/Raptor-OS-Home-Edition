use super::{AudioBackend, PlaybackError, PlaybackSource};
use raptor_core::models::{PlaybackAccess, PlayerState};
use rodio::{Decoder, OutputStream, Sink};
use std::io::Cursor;
use std::time::Duration;

/// Native Rodio backend for authorized HTTP(S) direct streams and previews.
///
/// The backend intentionally rejects embedded-player and handoff targets:
/// those must be handled by a provider player surface or the desktop shell.
pub struct RodioBackend {
    _stream: Option<OutputStream>,
    sink: Option<Sink>,
    client: reqwest::blocking::Client,
    state: PlayerState,
}

impl RodioBackend {
    pub fn new() -> Result<Self, PlaybackError> {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(30))
            .user_agent(concat!("RaptorMusic/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| PlaybackError::Backend(error.to_string()))?;
        Ok(Self { _stream: None, sink: None, client, state: PlayerState::Idle })
    }

    fn active_sink(&self) -> Result<&Sink, PlaybackError> {
        self.sink.as_ref().ok_or_else(|| PlaybackError::Backend("No track is loaded".into()))
    }
}

impl AudioBackend for RodioBackend {
    fn load(&mut self, source: &PlaybackSource) -> Result<(), PlaybackError> {
        match source.access {
            PlaybackAccess::DirectStream | PlaybackAccess::PreviewOnly => {}
            PlaybackAccess::Unavailable => return Err(PlaybackError::Unavailable),
            PlaybackAccess::EmbeddedPlayer | PlaybackAccess::ExternalHandoff => {
                return Err(PlaybackError::UnsupportedAccess);
            }
        }

        let url = reqwest::Url::parse(&source.uri)
            .map_err(|error| PlaybackError::SourceResolution(error.to_string()))?;
        if url.scheme() != "https" {
            return Err(PlaybackError::SourceResolution("Rodio accepts HTTPS streams only".into()));
        }

        self.state = PlayerState::Loading;
        let response = self.client.get(url).send()
            .map_err(|error| PlaybackError::Backend(error.to_string()))?
            .error_for_status()
            .map_err(|error| PlaybackError::Backend(error.to_string()))?;
        const MAX_BUFFER_BYTES: u64 = 512 * 1024 * 1024;
        if response.content_length().is_some_and(|length| length > MAX_BUFFER_BYTES) {
            self.state = PlayerState::Error;
            return Err(PlaybackError::Backend("Audio response exceeds the 512 MiB safety limit".into()));
        }
        let bytes = response.bytes()
            .map_err(|error| PlaybackError::Backend(error.to_string()))?
            .to_vec();

        if bytes.len() as u64 > MAX_BUFFER_BYTES {
            self.state = PlayerState::Error;
            return Err(PlaybackError::Backend("Audio response exceeds the 512 MiB safety limit".into()));
        }
        if bytes.is_empty() {
            self.state = PlayerState::Error;
            return Err(PlaybackError::Backend("The provider returned an empty audio response".into()));
        }

        let decoder = Decoder::new(Cursor::new(bytes))
            .map_err(|error| PlaybackError::Backend(format!("Unsupported audio response: {error}")))?;
        let (stream, stream_handle) = OutputStream::try_default()
            .map_err(|error| PlaybackError::Backend(error.to_string()))?;
        let sink = Sink::try_new(&stream_handle)
            .map_err(|error| PlaybackError::Backend(error.to_string()))?;
        sink.append(decoder);

        self.sink = Some(sink);
        self._stream = Some(stream);
        self.state = PlayerState::Playing;
        Ok(())
    }

    fn play(&mut self) -> Result<(), PlaybackError> {
        self.active_sink()?.play();
        self.state = PlayerState::Playing;
        Ok(())
    }

    fn pause(&mut self) -> Result<(), PlaybackError> {
        self.active_sink()?.pause();
        self.state = PlayerState::Paused;
        Ok(())
    }

    fn stop(&mut self) -> Result<(), PlaybackError> {
        if let Some(sink) = self.sink.take() { sink.stop(); }
        self._stream = None;
        self.state = PlayerState::Idle;
        Ok(())
    }

    fn seek(&mut self, position: Duration) -> Result<(), PlaybackError> {
        self.active_sink()?.try_seek(position)
            .map_err(|error| PlaybackError::Backend(error.to_string()))
    }

    fn position(&self) -> Duration {
        self.sink.as_ref().map(Sink::get_pos).unwrap_or_default()
    }

    fn state(&self) -> PlayerState {
        if self.sink.as_ref().is_some_and(Sink::empty) {
            PlayerState::Idle
        } else {
            self.state
        }
    }
}
