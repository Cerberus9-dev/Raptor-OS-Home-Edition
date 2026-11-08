use raptor_core::models::{PlaybackSource, PlayerState, PlayerEvent};
use crate::decoder::AudioDecoder;
use crate::ringbuf::{make_spsc, push_frames, pop_frames};
use crate::resample::LinearResampler;
use crate::channel::convert_channels;
use crossbeam_channel::{unbounded, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::thread;
use std::io::Write;
use std::time::Duration;
use std::path::PathBuf;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use uuid::Uuid;

#[derive(Debug)]
pub enum PlayerCommand {
    Play { source: PlaybackSource, track_id: Uuid, queue_entry_id: Uuid, session_token: Uuid },
    Pause { session_token: Uuid },
    Resume { session_token: Uuid },
    Seek { position_secs: f64, session_token: Uuid },
    Stop { session_token: Uuid },
}

fn download_audius_track(track_id: &str) -> Result<tempfile::NamedTempFile, String> {
    const MAX_STREAM_BYTES: u64 = 256 * 1024 * 1024;

    if track_id.is_empty()
        || !track_id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return Err("Audius returned an invalid track identifier".into());
    }

    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.17")
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(180))
        .build()
        .map_err(|e| format!("Could not initialize online audio: {e}"))?;

    let url = format!("https://api.audius.co/v1/tracks/{track_id}/stream");
    let response = client
        .get(&url)
        .query(&[("app_name", "RaptorMusic")])
        .send()
        .and_then(|r| r.error_for_status())
        .map_err(|e| format!("Audius could not provide this stream: {e}"))?;

    if response.content_length().is_some_and(|length| length > MAX_STREAM_BYTES) {
        return Err("This track is larger than Raptor Music's 256 MiB stream limit".into());
    }

    // Keep transient stream buffers in the per-user runtime directory (normally
    // tmpfs). NamedTempFile removes the data automatically when the session ends.
    let runtime_dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
        .unwrap_or_else(std::env::temp_dir);
    let stream_dir = runtime_dir.join("raptor-music");
    let temp_dir = if std::fs::create_dir_all(&stream_dir).is_ok() {
        stream_dir
    } else {
        std::env::temp_dir()
    };
    let mut temp = tempfile::Builder::new()
        .prefix("audius-stream-")
        .suffix(".mp3")
        .tempfile_in(temp_dir)
        .map_err(|e| format!("Could not create the temporary stream buffer: {e}"))?;

    let mut limited = response.take(MAX_STREAM_BYTES + 1);
    let copied = std::io::copy(&mut limited, &mut temp)
        .map_err(|e| format!("Online stream download failed: {e}"))?;
    if copied == 0 {
        return Err("Audius returned an empty audio stream".into());
    }
    if copied > MAX_STREAM_BYTES {
        return Err("This track is larger than Raptor Music's 256 MiB stream limit".into());
    }
    temp.flush()
        .map_err(|e| format!("Could not finish buffering the online track: {e}"))?;
    Ok(temp)
}

pub struct AudioPlayer {
    command_tx: Sender<PlayerCommand>,
    event_rx: Receiver<PlayerEvent>,
    state: Arc<Mutex<PlayerState>>,
    position_secs: Arc<Mutex<u64>>,
    duration_secs: Arc<Mutex<Option<u64>>>,
}

impl AudioPlayer {
    pub fn new() -> Self {
        let (command_tx, command_rx) = unbounded();
        let (event_tx, event_rx) = unbounded();
        let state = Arc::new(Mutex::new(PlayerState::Idle));
        let position_secs = Arc::new(Mutex::new(0));
        let duration_secs = Arc::new(Mutex::new(None));

        let state_clone = Arc::clone(&state);
        let pos_clone = Arc::clone(&position_secs);
        let duration_clone = Arc::clone(&duration_secs);

        thread::spawn(move || {
            Self::audio_worker_loop(command_rx, event_tx, state_clone, pos_clone, duration_clone);
        });

        Self { command_tx, event_rx, state, position_secs, duration_secs }
    }

    pub fn play(&self, source: PlaybackSource, track_id: Uuid, queue_entry_id: Uuid, session_token: Uuid) -> Result<(), String> {
        self.command_tx
            .send(PlayerCommand::Play { source, track_id, queue_entry_id, session_token })
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn pause(&self, session_token: Uuid) {
        let _ = self.command_tx.send(PlayerCommand::Pause { session_token });
    }

    pub fn resume(&self, session_token: Uuid) {
        let _ = self.command_tx.send(PlayerCommand::Resume { session_token });
    }

    pub fn seek(&self, position_secs: f64, session_token: Uuid) {
        if position_secs.is_finite() && position_secs >= 0.0 {
            let _ = self.command_tx.send(PlayerCommand::Seek { position_secs, session_token });
        }
    }

    pub fn stop(&self, session_token: Uuid) {
        let _ = self.command_tx.send(PlayerCommand::Stop { session_token });
    }

    pub fn get_state(&self) -> PlayerState {
        *self.state.lock().unwrap()
    }

    pub fn get_position_secs(&self) -> u64 {
        *self.position_secs.lock().unwrap()
    }

    pub fn get_duration_secs(&self) -> Option<u64> {
        *self.duration_secs.lock().unwrap()
    }

    pub fn poll_events(&self) -> Vec<PlayerEvent> {
        let mut events = Vec::new();
        while let Ok(ev) = self.event_rx.try_recv() {
            events.push(ev);
        }
        events
    }

    fn audio_worker_loop(
        rx: Receiver<PlayerCommand>,
        event_tx: Sender<PlayerEvent>,
        state: Arc<Mutex<PlayerState>>,
        position_secs: Arc<Mutex<u64>>,
        duration_secs: Arc<Mutex<Option<u64>>>,
    ) {
        let host = cpal::default_host();
        let is_paused_shared = Arc::new(AtomicBool::new(false));
        let mut active_session_token: Option<Uuid> = None;
        let mut preserve_paused = false;
        let mut remote_audio_file: Option<tempfile::NamedTempFile> = None;

        while let Ok(cmd) = rx.recv() {
            let (mut active_source, mut active_track_id, mut active_queue_entry_id, mut session_token, mut start_offset_secs) = match cmd {
                PlayerCommand::Play { source, track_id, queue_entry_id, session_token } => {
                    remote_audio_file = None;
                    active_session_token = Some(session_token);
                    is_paused_shared.store(false, Ordering::Release);
                    preserve_paused = false;
                    (source, track_id, queue_entry_id, session_token, 0.0_f64)
                }
                PlayerCommand::Stop { session_token } => {
                    if Some(session_token) == active_session_token {
                        *state.lock().unwrap() = PlayerState::Idle;
                        let _ = event_tx.send(PlayerEvent::Stopped { session_token });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                    }
                    continue;
                }
                PlayerCommand::Pause { session_token } => {
                    if Some(session_token) == active_session_token {
                        is_paused_shared.store(true, Ordering::Release);
                        *state.lock().unwrap() = PlayerState::Paused;
                        let _ = event_tx.send(PlayerEvent::Paused { session_token });
                    }
                    continue;
                }
                PlayerCommand::Resume { session_token } => {
                    if Some(session_token) == active_session_token {
                        is_paused_shared.store(false, Ordering::Release);
                        *state.lock().unwrap() = PlayerState::Playing;
                        let _ = event_tx.send(PlayerEvent::Resumed { session_token });
                    }
                    continue;
                }
                PlayerCommand::Seek { .. } => continue,
            };

            'play_session: loop {
                preserve_paused = is_paused_shared.load(Ordering::Acquire);
                if !preserve_paused {
                    *state.lock().unwrap() = PlayerState::Loading;
                }
                is_paused_shared.store(preserve_paused, Ordering::Release);
                *position_secs.lock().unwrap() = start_offset_secs.max(0.0).floor() as u64;
                *duration_secs.lock().unwrap() = None;

                let device = match host.default_output_device() {
                    Some(d) => d,
                    None => {
                        *state.lock().unwrap() = PlayerState::Error;
                        let _ = event_tx.send(PlayerEvent::PlaybackFailed {
                            session_token,
                            error_message: "No default audio output device available".into(),
                        });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                        remote_audio_file = None;
                        break 'play_session;
                    }
                };

                let path_result: Result<PathBuf, String> = match &active_source {
                    PlaybackSource::LocalFile { path } => {
                        remote_audio_file = None;
                        Ok(path.clone())
                    }
                    PlaybackSource::RemoteStream { provider_id, provider_track_id }
                        if provider_id == "audius" =>
                    {
                        if remote_audio_file.is_none() {
                            match download_audius_track(provider_track_id) {
                                Ok(file) => remote_audio_file = Some(file),
                                Err(error) => {
                                    *state.lock().unwrap() = PlayerState::Error;
                                    let _ = event_tx.send(PlayerEvent::PlaybackFailed {
                                        session_token,
                                        error_message: error,
                                    });
                                    let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                    active_session_token = None;
                                    remote_audio_file = None;
                                    break 'play_session;
                                }
                            }
                        }
                        remote_audio_file
                            .as_ref()
                            .map(|file| file.path().to_path_buf())
                            .ok_or_else(|| "Online audio buffer was not created".to_string())
                    }
                    PlaybackSource::RemoteStream { provider_id, .. } => {
                        Err(format!("Unsupported online music provider: {provider_id}"))
                    }
                    PlaybackSource::Unknown { raw_type } => {
                        Err(format!("Unsupported playback source: {raw_type}"))
                    }
                };
                let path = match path_result {
                    Ok(path) => path,
                    Err(error) => {
                        *state.lock().unwrap() = PlayerState::Error;
                        let _ = event_tx.send(PlayerEvent::PlaybackFailed {
                            session_token,
                            error_message: error,
                        });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                        remote_audio_file = None;
                        break 'play_session;
                    }
                };

                let mut decoder = match AudioDecoder::new(&path) {
                    Ok(dec) => dec,
                    Err(e) => {
                        *state.lock().unwrap() = PlayerState::Error;
                        let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: e });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                        remote_audio_file = None;
                        break 'play_session;
                    }
                };

                *duration_secs.lock().unwrap() = decoder.duration_secs();

                let config = match device.default_output_config() {
                    Ok(c) => c,
                    Err(e) => {
                        *state.lock().unwrap() = PlayerState::Error;
                        let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: e.to_string() });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                        remote_audio_file = None;
                        break 'play_session;
                    }
                };

                let target_channels = config.channels() as usize;
                let target_sample_rate = config.sample_rate().0;
                let decoder_sample_rate = decoder.sample_rate();
                let decoder_channels = decoder.channels();
                let mut frames_to_skip =
                    (start_offset_secs.max(0.0) * decoder_sample_rate as f64).round() as u64;

                let mut resampler = match LinearResampler::new(decoder_channels, decoder_sample_rate, target_sample_rate) {
                    Ok(r) => r,
                    Err(e) => {
                        *state.lock().unwrap() = PlayerState::Error;
                        let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: e });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                        remote_audio_file = None;
                        break 'play_session;
                    }
                };

                let (mut producer, mut consumer) = make_spsc(65536);
                let (err_tx, err_rx) = unbounded::<cpal::StreamError>();
                let err_tx_cb = err_tx.clone();
                let err_fn = move |err| {
                    let _ = err_tx_cb.send(err);
                };

                let consumed_base_frames =
                    (start_offset_secs.max(0.0) * target_sample_rate as f64).round() as u64;
                let consumed_fractional_accumulator = Arc::new(AtomicU64::new(consumed_base_frames));
                let samples_written = Arc::new(AtomicUsize::new(0));
                let samples_read = Arc::new(AtomicUsize::new(0));

                let acc_cb = Arc::clone(&consumed_fractional_accumulator);
                let is_paused_cb = Arc::clone(&is_paused_shared);
                let written_cb = Arc::clone(&samples_written);
                let read_cb = Arc::clone(&samples_read);

                let frame_chunk_frames = 1024;
                let sample_chunk_size = frame_chunk_frames * target_channels;

                let sample_format = config.sample_format();
                let stream_result = match sample_format {
                    cpal::SampleFormat::F32 => {
                        let cfg: cpal::StreamConfig = config.into();
                        device.build_output_stream(
                            &cfg,
                            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                                if is_paused_cb.load(Ordering::Acquire) {
                                    data.fill(0.0);
                                } else {
                                    let read_count = pop_frames(&mut consumer, data, target_channels);
                                    data[read_count..].fill(0.0);
                                    if read_count > 0 {
                                        read_cb.fetch_add(read_count, Ordering::Relaxed);
                                        let frames_played = read_count / target_channels;
                                        acc_cb.fetch_add(frames_played as u64, Ordering::Relaxed);
                                    }
                                }
                            },
                            err_fn,
                            None,
                        )
                    }
                    cpal::SampleFormat::I16 => {
                        let cfg: cpal::StreamConfig = config.into();
                        let acc_cb_i16 = Arc::clone(&consumed_fractional_accumulator);
                        let is_paused_i16 = Arc::clone(&is_paused_shared);
                        let read_cb_i16 = Arc::clone(&samples_read);
                        let mut temp_buf = vec![0.0f32; sample_chunk_size];
                        device.build_output_stream(
                            &cfg,
                            move |data: &mut [i16], _: &cpal::OutputCallbackInfo| {
                                if is_paused_i16.load(Ordering::Acquire) {
                                    data.fill(0);
                                } else {
                                    let mut offset = 0;
                                    let mut total_read = 0;
                                    while offset < data.len() {
                                        let chunk = std::cmp::min(data.len() - offset, temp_buf.len());
                                        let n = pop_frames(&mut consumer, &mut temp_buf[..chunk], target_channels);
                                        if n == 0 {
                                            data[offset..].fill(0);
                                            break;
                                        }
                                        for i in 0..n {
                                            data[offset + i] = (temp_buf[i].clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
                                        }
                                        offset += n;
                                        total_read += n;
                                    }
                                    if total_read > 0 {
                                        read_cb_i16.fetch_add(total_read, Ordering::Relaxed);
                                        let frames_played = total_read / target_channels;
                                        acc_cb_i16.fetch_add(frames_played as u64, Ordering::Relaxed);
                                    }
                                }
                            },
                            err_fn,
                            None,
                        )
                    }
                    cpal::SampleFormat::U16 => {
                        let cfg: cpal::StreamConfig = config.into();
                        let acc_cb_u16 = Arc::clone(&consumed_fractional_accumulator);
                        let is_paused_u16 = Arc::clone(&is_paused_shared);
                        let read_cb_u16 = Arc::clone(&samples_read);
                        let mut temp_buf = vec![0.0f32; sample_chunk_size];
                        device.build_output_stream(
                            &cfg,
                            move |data: &mut [u16], _: &cpal::OutputCallbackInfo| {
                                if is_paused_u16.load(Ordering::Acquire) {
                                    data.fill(0);
                                } else {
                                    let mut offset = 0;
                                    let mut total_read = 0;
                                    while offset < data.len() {
                                        let chunk = std::cmp::min(data.len() - offset, temp_buf.len());
                                        let n = pop_frames(&mut consumer, &mut temp_buf[..chunk], target_channels);
                                        if n == 0 {
                                            data[offset..].fill(0);
                                            break;
                                        }
                                        for i in 0..n {
                                            data[offset + i] = ((temp_buf[i].clamp(-1.0, 1.0) + 1.0) * 0.5 * u16::MAX as f32) as u16;
                                        }
                                        offset += n;
                                        total_read += n;
                                    }
                                    if total_read > 0 {
                                        read_cb_u16.fetch_add(total_read, Ordering::Relaxed);
                                        let frames_played = total_read / target_channels;
                                        acc_cb_u16.fetch_add(frames_played as u64, Ordering::Relaxed);
                                    }
                                }
                            },
                            err_fn,
                            None,
                        )
                    }
                    _ => {
                        *state.lock().unwrap() = PlayerState::Error;
                        let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: "Unsupported sample format".into() });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                        remote_audio_file = None;
                        break 'play_session;
                    }
                };

                let stream = match stream_result {
                    Ok(s) => s,
                    Err(e) => {
                        *state.lock().unwrap() = PlayerState::Error;
                        let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: e.to_string() });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                        remote_audio_file = None;
                        break 'play_session;
                    }
                };

                if stream.play().is_err() {
                    *state.lock().unwrap() = PlayerState::Error;
                    let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: "Failed to start audio stream".into() });
                    let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                    active_session_token = None;
                    remote_audio_file = None;
                    break 'play_session;
                }

                if preserve_paused {
                    *state.lock().unwrap() = PlayerState::Paused;
                } else {
                    *state.lock().unwrap() = PlayerState::Playing;
                }
                let _ = event_tx.send(PlayerEvent::SessionStarted {
                    session_token,
                    track_id: active_track_id,
                    queue_entry_id: active_queue_entry_id,
                });
                if preserve_paused {
                    let _ = event_tx.send(PlayerEvent::Paused { session_token });
                }

                let mut eof_reached = false;

                loop {
                    if let Ok(_err) = err_rx.try_recv() {
                        drop(stream);
                        *state.lock().unwrap() = PlayerState::Error;
                        let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: "Output stream error".into() });
                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                        active_session_token = None;
                        remote_audio_file = None;
                        break 'play_session;
                    }

                    match rx.try_recv() {
                        Ok(PlayerCommand::Stop { session_token: cmd_token }) => {
                            if cmd_token == session_token {
                                drop(stream);
                                *state.lock().unwrap() = PlayerState::Idle;
                                let _ = event_tx.send(PlayerEvent::Stopped { session_token });
                                let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                active_session_token = None;
                                remote_audio_file = None;
                                break 'play_session;
                            }
                        }
                        Ok(PlayerCommand::Pause { session_token: cmd_token }) => {
                            if cmd_token == session_token {
                                is_paused_shared.store(true, Ordering::Release);
                                *state.lock().unwrap() = PlayerState::Paused;
                                let _ = event_tx.send(PlayerEvent::Paused { session_token });
                            }
                        }
                        Ok(PlayerCommand::Resume { session_token: cmd_token }) => {
                            if cmd_token == session_token {
                                is_paused_shared.store(false, Ordering::Release);
                                *state.lock().unwrap() = PlayerState::Playing;
                                let _ = event_tx.send(PlayerEvent::Resumed { session_token });
                            }
                        }
                        Ok(PlayerCommand::Play { source, track_id, queue_entry_id, session_token: new_token }) => {
                            drop(stream);
                            let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                            remote_audio_file = None;
                            active_source = source;
                            active_track_id = track_id;
                            active_queue_entry_id = queue_entry_id;
                            active_session_token = Some(new_token);
                            session_token = new_token;
                            start_offset_secs = 0.0;
                            preserve_paused = false;
                            is_paused_shared.store(false, Ordering::Release);
                            continue 'play_session;
                        }
                        Ok(PlayerCommand::Seek { position_secs, session_token: cmd_token }) => {
                            if cmd_token == session_token {
                                drop(stream);
                                start_offset_secs = position_secs;
                                preserve_paused = is_paused_shared.load(Ordering::Acquire);
                                continue 'play_session;
                            }
                        }
                        Err(TryRecvError::Empty) => {}
                        Err(TryRecvError::Disconnected) => {
                            drop(stream);
                            return;
                        }
                    }

                    let total_frames = consumed_fractional_accumulator.load(Ordering::Relaxed);
                    if target_sample_rate > 0 {
                        *position_secs.lock().unwrap() = total_frames / target_sample_rate as u64;
                    }

                    if is_paused_shared.load(Ordering::Acquire) {
                        thread::sleep(std::time::Duration::from_millis(50));
                        continue;
                    }

                    if !eof_reached {
                        match decoder.next_packet_samples() {
                            Ok(Some(mut decoded)) => {
                                if frames_to_skip > 0 {
                                    let available_frames = decoded.len() / decoder_channels;
                                    let skipped_frames =
                                        frames_to_skip.min(available_frames as u64) as usize;
                                    frames_to_skip -= skipped_frames as u64;
                                    if skipped_frames == available_frames {
                                        continue;
                                    }
                                    decoded.drain(..skipped_frames * decoder_channels);
                                }
                                let raw_samples = &decoded;

                                let mut resampled = Vec::new();
                                if let Err(e) = resampler.process(raw_samples, &mut resampled) {
                                    *state.lock().unwrap() = PlayerState::Error;
                                    let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: e });
                                    let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                    active_session_token = None;
                                    remote_audio_file = None;
                                    break 'play_session;
                                }

                                let mut mapped = Vec::new();
                                if let Err(e) = convert_channels(&resampled, decoder_channels, target_channels, &mut mapped) {
                                    *state.lock().unwrap() = PlayerState::Error;
                                    let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: e });
                                    let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                    active_session_token = None;
                                    remote_audio_file = None;
                                    break 'play_session;
                                }

                                let frame_size = target_channels;
                                let aligned_len = (mapped.len() / frame_size) * frame_size;
                                let final_chunk = &mapped[..aligned_len];

                                let mut pushed = 0;
                                while pushed < final_chunk.len() {
                                    if let Ok(_err) = err_rx.try_recv() {
                                        drop(stream);
                                        *state.lock().unwrap() = PlayerState::Error;
                                        let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: "Output stream error".into() });
                                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                        active_session_token = None;
                                        remote_audio_file = None;
                                        break 'play_session;
                                    }
                                    if let Ok(cmd) = rx.try_recv() {
                                        match cmd {
                                            PlayerCommand::Stop { session_token: cmd_token } => {
                                                if cmd_token == session_token {
                                                    drop(stream);
                                                    *state.lock().unwrap() = PlayerState::Idle;
                                                    let _ = event_tx.send(PlayerEvent::Stopped { session_token });
                                                    let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                                    active_session_token = None;
                                                    remote_audio_file = None;
                                                    break 'play_session;
                                                }
                                            }
                                            PlayerCommand::Pause { session_token: cmd_token } => {
                                                if cmd_token == session_token {
                                                    is_paused_shared.store(true, Ordering::Release);
                                                    *state.lock().unwrap() = PlayerState::Paused;
                                                    let _ = event_tx.send(PlayerEvent::Paused { session_token });
                                                }
                                            }
                                            PlayerCommand::Resume { session_token: cmd_token } => {
                                                if cmd_token == session_token {
                                                    is_paused_shared.store(false, Ordering::Release);
                                                    *state.lock().unwrap() = PlayerState::Playing;
                                                    let _ = event_tx.send(PlayerEvent::Resumed { session_token });
                                                }
                                            }
                                            PlayerCommand::Play { source, track_id, queue_entry_id, session_token: new_token } => {
                                                drop(stream);
                                                let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                                active_source = source;
                                                active_track_id = track_id;
                                                active_queue_entry_id = queue_entry_id;
                                                active_session_token = Some(new_token);
                                                session_token = new_token;
                                                start_offset_secs = 0.0;
                                                preserve_paused = false;
                                                is_paused_shared.store(false, Ordering::Release);
                                                continue 'play_session;
                                            }
                                            PlayerCommand::Seek { position_secs, session_token: cmd_token } => {
                                                if cmd_token == session_token {
                                                    drop(stream);
                                                    start_offset_secs = position_secs;
                                                    preserve_paused = is_paused_shared.load(Ordering::Acquire);
                                                    continue 'play_session;
                                                }
                                            }
                                        }
                                    }

                                    let n = push_frames(&mut producer, &final_chunk[pushed..], target_channels);
                                    if n > 0 {
                                        written_cb.fetch_add(n, Ordering::Relaxed);
                                        pushed += n;
                                    } else {
                                        thread::sleep(std::time::Duration::from_millis(2));
                                    }
                                }
                            }
                            Ok(None) => {
                                let mut flushed = Vec::new();
                                resampler.flush(&mut flushed);
                                let mut mapped_flush = Vec::new();
                                match convert_channels(&flushed, decoder_channels, target_channels, &mut mapped_flush) {
                                    Ok(()) => {
                                        let frame_size = target_channels;
                                        let aligned_len = (mapped_flush.len() / frame_size) * frame_size;
                                        let final_flush_chunk = &mapped_flush[..aligned_len];

                                        let mut pushed = 0;
                                        while pushed < final_flush_chunk.len() {
                                            if let Ok(_err) = err_rx.try_recv() {
                                                drop(stream);
                                                *state.lock().unwrap() = PlayerState::Error;
                                                let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: "Output stream error".into() });
                                                let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                                active_session_token = None;
                                                remote_audio_file = None;
                                                break 'play_session;
                                            }
                                            if let Ok(cmd) = rx.try_recv() {
                                                match cmd {
                                                    PlayerCommand::Stop { session_token: cmd_token } => {
                                                        if cmd_token == session_token {
                                                            drop(stream);
                                                            *state.lock().unwrap() = PlayerState::Idle;
                                                            let _ = event_tx.send(PlayerEvent::Stopped { session_token });
                                                            let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                                            active_session_token = None;
                                                            remote_audio_file = None;
                                                            break 'play_session;
                                                        }
                                                    }
                                                    PlayerCommand::Play { source, track_id, queue_entry_id, session_token: new_token } => {
                                                        drop(stream);
                                                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                                        active_source = source;
                                                        active_track_id = track_id;
                                                        active_queue_entry_id = queue_entry_id;
                                                        active_session_token = Some(new_token);
                                                        session_token = new_token;
                                                        start_offset_secs = 0.0;
                                                        preserve_paused = false;
                                                        is_paused_shared.store(false, Ordering::Release);
                                                        continue 'play_session;
                                                    }
                                                    PlayerCommand::Seek { position_secs, session_token: cmd_token } => {
                                                        if cmd_token == session_token {
                                                            drop(stream);
                                                            start_offset_secs = position_secs;
                                                            preserve_paused = is_paused_shared.load(Ordering::Acquire);
                                                            continue 'play_session;
                                                        }
                                                    }
                                                    _ => {}
                                                }
                                            }
                                            let n = push_frames(&mut producer, &final_flush_chunk[pushed..], target_channels);
                                            if n > 0 {
                                                written_cb.fetch_add(n, Ordering::Relaxed);
                                                pushed += n;
                                            } else {
                                                thread::sleep(std::time::Duration::from_millis(2));
                                            }
                                        }
                                    }
                                    Err(e) => {
                                        drop(stream);
                                        *state.lock().unwrap() = PlayerState::Error;
                                        let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: e });
                                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                        active_session_token = None;
                                        remote_audio_file = None;
                                        break 'play_session;
                                    }
                                }
                                eof_reached = true;
                            }
                            Err(e) => {
                                drop(stream);
                                *state.lock().unwrap() = PlayerState::Error;
                                let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: e });
                                let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                active_session_token = None;
                                remote_audio_file = None;
                                break 'play_session;
                            }
                        }
                    } else {
                        if let Ok(_err) = err_rx.try_recv() {
                            drop(stream);
                            *state.lock().unwrap() = PlayerState::Error;
                            let _ = event_tx.send(PlayerEvent::PlaybackFailed { session_token, error_message: "Output stream error".into() });
                            let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                            active_session_token = None;
                            remote_audio_file = None;
                            break 'play_session;
                        }
                        if let Ok(cmd) = rx.try_recv() {
                            match cmd {
                                PlayerCommand::Stop { session_token: cmd_token } => {
                                    if cmd_token == session_token {
                                        drop(stream);
                                        *state.lock().unwrap() = PlayerState::Idle;
                                        let _ = event_tx.send(PlayerEvent::Stopped { session_token });
                                        let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                        active_session_token = None;
                                        remote_audio_file = None;
                                        break 'play_session;
                                    }
                                }
                                PlayerCommand::Play { source, track_id, queue_entry_id, session_token: new_token } => {
                                    drop(stream);
                                    let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                                    active_source = source;
                                    active_track_id = track_id;
                                    active_queue_entry_id = queue_entry_id;
                                    active_session_token = Some(new_token);
                                    session_token = new_token;
                                    start_offset_secs = 0.0;
                                    preserve_paused = false;
                                    is_paused_shared.store(false, Ordering::Release);
                                    continue 'play_session;
                                }
                                PlayerCommand::Seek { position_secs, session_token: cmd_token } => {
                                    if cmd_token == session_token {
                                        drop(stream);
                                        start_offset_secs = position_secs;
                                        preserve_paused = is_paused_shared.load(Ordering::Acquire);
                                        continue 'play_session;
                                    }
                                }
                                PlayerCommand::Pause { session_token: cmd_token } => {
                                    if cmd_token == session_token {
                                        is_paused_shared.store(true, Ordering::Release);
                                        *state.lock().unwrap() = PlayerState::Paused;
                                        let _ = event_tx.send(PlayerEvent::Paused { session_token });
                                    }
                                }
                                PlayerCommand::Resume { session_token: cmd_token } => {
                                    if cmd_token == session_token {
                                        is_paused_shared.store(false, Ordering::Release);
                                        *state.lock().unwrap() = PlayerState::Playing;
                                        let _ = event_tx.send(PlayerEvent::Resumed { session_token });
                                    }
                                }
                            }
                        }

                        let written = samples_written.load(Ordering::Relaxed);
                        let read = samples_read.load(Ordering::Relaxed);
                        if read >= written {
                            thread::sleep(std::time::Duration::from_millis(60));
                            let _ = event_tx.send(PlayerEvent::NaturalEof { session_token, queue_entry_id: active_queue_entry_id });
                            let _ = event_tx.send(PlayerEvent::SessionTerminated { session_token });
                            drop(stream);
                            *state.lock().unwrap() = PlayerState::Idle;
                            active_session_token = None;
                            remote_audio_file = None;
                            break 'play_session;
                        }
                        thread::sleep(std::time::Duration::from_millis(15));
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use raptor_core::models::PlaybackSource;
    use std::path::PathBuf;

    #[test]
    fn test_player_lifecycle_and_session_validation() {
        let player = AudioPlayer::new();
        assert_eq!(player.get_state(), PlayerState::Idle);

        let token1 = Uuid::new_v4();
        let token2 = Uuid::new_v4();

        player.pause(token1);
        player.resume(token1);
        player.stop(token1);

        let fake_source = PlaybackSource::LocalFile { path: PathBuf::from("nonexistent.wav") };
        let track_id = Uuid::new_v4();
        let queue_entry_id = Uuid::new_v4();

        assert!(player.play(fake_source.clone(), track_id, queue_entry_id, token2).is_ok());
        std::thread::sleep(std::time::Duration::from_millis(50));

        let events = player.poll_events();
        assert!(!events.is_empty() || player.get_state() == PlayerState::Error);
    }
}
