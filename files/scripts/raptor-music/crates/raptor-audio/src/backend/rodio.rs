use super::{AudioBackend, PlaybackError, PlaybackSource};
use raptor_core::models::{PlaybackAccess, PlayerState};
use rodio::{Decoder, OutputStream, OutputStreamHandle, Sink};
use std::io::{Cursor, Read};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const MAX_BUFFER_BYTES: u64 = 512 * 1024 * 1024;

enum Command {
    Load(PlaybackSource, SyncSender<Result<(), String>>),
    Play(SyncSender<Result<(), String>>),
    Pause(SyncSender<Result<(), String>>),
    Stop(SyncSender<Result<(), String>>),
    Seek(Duration, SyncSender<Result<(), String>>),
    Position(SyncSender<Duration>),
    State(SyncSender<PlayerState>),
    Shutdown,
}

/// Native Rodio backend for authorized HTTPS direct streams and previews.
///
/// Rodio 0.20's OutputStream is thread-affine and is not Send. The backend
/// therefore owns a command channel while a dedicated worker owns the output
/// stream, handle and sink for their entire lifetime. Embedded-player and
/// external-handoff targets stay outside the native audio engine.
pub struct RodioBackend {
    commands: Sender<Command>,
    worker: Option<JoinHandle<()>>,
}

impl RodioBackend {
    pub fn new() -> Result<Self, PlaybackError> {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(30))
            .user_agent(concat!("RaptorMusic/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| PlaybackError::Backend(error.to_string()))?;

        let (commands, receiver) = mpsc::channel();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let worker = thread::Builder::new()
            .name("raptor-rodio-output".into())
            .spawn(move || {
                match OutputStream::try_default() {
                    Ok((stream, stream_handle)) => {
                        let _ = ready_tx.send(Ok(()));
                        Self::run_worker(receiver, stream, stream_handle, client);
                    }
                    Err(error) => {
                        let _ = ready_tx.send(Err(error.to_string()));
                    }
                }
            })
            .map_err(|error| PlaybackError::Backend(error.to_string()))?;

        match ready_rx.recv() {
            Ok(Ok(())) => Ok(Self { commands, worker: Some(worker) }),
            Ok(Err(error)) => {
                let _ = worker.join();
                Err(PlaybackError::Backend(error))
            }
            Err(error) => {
                let _ = worker.join();
                Err(PlaybackError::Backend(error.to_string()))
            }
        }
    }

    fn run_worker(
        receiver: Receiver<Command>,
        _stream: OutputStream,
        stream_handle: OutputStreamHandle,
        client: reqwest::blocking::Client,
    ) {
        let mut sink: Option<Sink> = None;

        while let Ok(command) = receiver.recv() {
            match command {
                Command::Load(source, reply) => {
                    let result = Self::load_source(&client, &stream_handle, &mut sink, &source);
                    let _ = reply.send(result);
                }
                Command::Play(reply) => {
                    let result = sink.as_ref()
                        .ok_or_else(|| "No track is loaded".to_owned())
                        .map(|active| active.play());
                    let _ = reply.send(result);
                }
                Command::Pause(reply) => {
                    let result = sink.as_ref()
                        .ok_or_else(|| "No track is loaded".to_owned())
                        .map(|active| active.pause());
                    let _ = reply.send(result);
                }
                Command::Stop(reply) => {
                    if let Some(active) = sink.take() { active.stop(); }
                    let _ = reply.send(Ok(()));
                }
                Command::Seek(position, reply) => {
                    let result = sink.as_ref()
                        .ok_or_else(|| "No track is loaded".to_owned())
                        .and_then(|active| active.try_seek(position).map_err(|error| error.to_string()));
                    let _ = reply.send(result);
                }
                Command::Position(reply) => {
                    let position = sink.as_ref().map(Sink::get_pos).unwrap_or_default();
                    let _ = reply.send(position);
                }
                Command::State(reply) => {
                    let state = match sink.as_ref() {
                        None => PlayerState::Idle,
                        Some(active) if active.empty() => PlayerState::Idle,
                        Some(active) if active.is_paused() => PlayerState::Paused,
                        Some(_) => PlayerState::Playing,
                    };
                    let _ = reply.send(state);
                }
                Command::Shutdown => {
                    if let Some(active) = sink.take() { active.stop(); }
                    break;
                }
            }
        }
    }

    fn load_source(
        client: &reqwest::blocking::Client,
        stream_handle: &OutputStreamHandle,
        sink: &mut Option<Sink>,
        source: &PlaybackSource,
    ) -> Result<(), String> {
        match source.access {
            PlaybackAccess::DirectStream | PlaybackAccess::PreviewOnly => {}
            PlaybackAccess::Unavailable => return Err("Track is unavailable".into()),
            PlaybackAccess::EmbeddedPlayer | PlaybackAccess::ExternalHandoff => {
                return Err("Embedded and handoff targets are not native audio streams".into());
            }
        }

        let url = reqwest::Url::parse(&source.uri).map_err(|error| error.to_string())?;
        if url.scheme() != "https" {
            return Err("Rodio accepts HTTPS streams only".into());
        }

        let mut response = client.get(url).send()
            .map_err(|error| error.to_string())?
            .error_for_status()
            .map_err(|error| error.to_string())?;
        if response.content_length().is_some_and(|length| length > MAX_BUFFER_BYTES) {
            return Err("Audio response exceeds the 512 MiB safety limit".into());
        }
        let mut bytes = Vec::new();
        response.take(MAX_BUFFER_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|error| error.to_string())?;
        if bytes.len() as u64 > MAX_BUFFER_BYTES {
            return Err("Audio response exceeds the 512 MiB safety limit".into());
        }
        if bytes.is_empty() {
            return Err("The provider returned an empty audio response".into());
        }

        let decoder = Decoder::new(Cursor::new(bytes))
            .map_err(|error| format!("Unsupported audio response: {error}"))?;
        let replacement = Sink::try_new(stream_handle).map_err(|error| error.to_string())?;
        replacement.append(decoder);
        if let Some(previous) = sink.replace(replacement) { previous.stop(); }
        Ok(())
    }

    fn request(
        &self,
        build: impl FnOnce(SyncSender<Result<(), String>>) -> Command,
    ) -> Result<(), PlaybackError> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.commands.send(build(reply_tx))
            .map_err(|error| PlaybackError::Backend(error.to_string()))?;
        reply_rx.recv()
            .map_err(|error| PlaybackError::Backend(error.to_string()))?
            .map_err(PlaybackError::Backend)
    }
}

impl AudioBackend for RodioBackend {
    fn load(&mut self, source: &PlaybackSource) -> Result<(), PlaybackError> {
        if source.access == PlaybackAccess::Unavailable {
            return Err(PlaybackError::Unavailable);
        }
        self.request(|reply| Command::Load(source.clone(), reply))
    }

    fn play(&mut self) -> Result<(), PlaybackError> {
        self.request(Command::Play)
    }

    fn pause(&mut self) -> Result<(), PlaybackError> {
        self.request(Command::Pause)
    }

    fn stop(&mut self) -> Result<(), PlaybackError> {
        self.request(Command::Stop)
    }

    fn seek(&mut self, position: Duration) -> Result<(), PlaybackError> {
        self.request(|reply| Command::Seek(position, reply))
    }

    fn position(&self) -> Duration {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        if self.commands.send(Command::Position(reply_tx)).is_err() {
            return Duration::ZERO;
        }
        reply_rx.recv_timeout(Duration::from_millis(250)).unwrap_or(Duration::ZERO)
    }

    fn state(&self) -> PlayerState {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        if self.commands.send(Command::State(reply_tx)).is_err() {
            return PlayerState::Error;
        }
        reply_rx.recv_timeout(Duration::from_millis(250)).unwrap_or(PlayerState::Error)
    }
}

impl Drop for RodioBackend {
    fn drop(&mut self) {
        let _ = self.commands.send(Command::Shutdown);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
