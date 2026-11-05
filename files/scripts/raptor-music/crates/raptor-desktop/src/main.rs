slint::include_modules!();

use raptor_audio::player::AudioPlayer;
use raptor_audio::decoder::AudioDecoder;
use raptor_library::{LibraryDatabase, QueueEntry};
use raptor_core::models::{Track, PlaybackSource, PlayerState, PlayerEvent};
use std::sync::{Arc, Mutex};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use uuid::Uuid;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let db_path = music_data_dir()?.join("raptor_music.db");
    let db = Arc::new(Mutex::new(LibraryDatabase::new(&db_path)?));
    let player = Arc::new(AudioPlayer::new());

    let ui = MainWindow::new()?;
    refresh_track_list(&ui, &db);
    refresh_queue_list(&ui, &db);
    refresh_playlist_list(&ui, &db);

    let manual_stopped = Arc::new(AtomicBool::new(false));
    let active_session_token: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    let active_playing_queue_entry_id: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    let last_seek_at: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));

    {
        let db_lock = db.lock().unwrap();
        if let Ok(Some(saved_id_str)) = db_lock.get_state_value("current_track_id") {
            if let Ok(uuid) = Uuid::parse_str(&saved_id_str) {
                let tracks = db_lock.get_all_tracks().unwrap_or_default();
                if let Some(t) = tracks.iter().find(|tr| tr.id == uuid) {
                    let title = t.title.clone();
                    let artist = t.artist.clone();
                    drop(db_lock);
                    ui.set_current_track_title(title.into());
                    ui.set_current_track_artist(artist.into());
                }
            }
        }
    }

    let db_path_clone = db_path.clone();
    let ui_handle_scan = ui.as_weak();

    ui.on_scan_directory_clicked(move || {
        if let Some(folder) = rfd::FileDialog::new().pick_folder() {
            let db_path_inner = db_path_clone.clone();
            let ui_weak = ui_handle_scan.clone();
            std::thread::spawn(move || {
                if let Ok(mut worker_db) = LibraryDatabase::new(db_path_inner) {
                    walk_dir_and_import(&folder, &mut worker_db);
                    let updated_tracks = worker_db.get_all_tracks().unwrap_or_default();
                    let mut new_slint_tracks = Vec::new();
                    for t in &updated_tracks {
                        let dur = t.duration_secs.unwrap_or(0);
                        new_slint_tracks.push(TrackData {
                            id: t.id.to_string().into(),
                            title: t.title.clone().into(),
                            artist: t.artist.clone().into(),
                            album: t.album.clone().unwrap_or_default().into(),
                            duration: format!("{}:{:02}", dur / 60, dur % 60).into(),
                        });
                    }

                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_track_list(slint::ModelRc::new(slint::VecModel::from(new_slint_tracks)));
                        }
                    });
                }
            });
        }
    });

    let db_for_select = Arc::clone(&db);
    let ui_handle_select = ui.as_weak();
    ui.on_track_selected(move |idx| {
        let db_lock = db_for_select.lock().unwrap();
        let tracks = db_lock.get_all_tracks().unwrap_or_default();
        if tracks.get(idx as usize).is_some() {
            drop(db_lock);
            if let Some(ui) = ui_handle_select.upgrade() {
                ui.set_selected_track_index(idx);
            }
        }
    });

    let ui_handle_qselect = ui.as_weak();
    ui.on_queue_selected(move |qidx| {
        if let Some(ui) = ui_handle_qselect.upgrade() {
            ui.set_selected_queue_index(qidx);
        }
    });

    let ui_handle_playlist_select = ui.as_weak();
    ui.on_playlist_selected(move |pidx| {
        if let Some(ui) = ui_handle_playlist_select.upgrade() {
            ui.set_selected_playlist_index(pidx);
        }
    });

    let db_for_playlist_create = Arc::clone(&db);
    let ui_handle_playlist_create = ui.as_weak();
    ui.on_create_playlist_clicked(move || {
        let ui = match ui_handle_playlist_create.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let name = ui.get_new_playlist_name().to_string();
        if name.trim().is_empty() {
            ui.set_player_state_label("Enter a playlist name".into());
            return;
        }
        if db_for_playlist_create.lock().unwrap().create_playlist(name.trim(), None).is_ok() {
            ui.set_new_playlist_name("".into());
            refresh_playlist_list(&ui, &db_for_playlist_create);
            ui.set_player_state_label("Playlist created".into());
        }
    });

    let db_for_playlist_add = Arc::clone(&db);
    let ui_handle_playlist_add = ui.as_weak();
    ui.on_add_to_playlist_clicked(move || {
        let ui = match ui_handle_playlist_add.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let track_index = ui.get_selected_track_index();
        let playlist_index = ui.get_selected_playlist_index();
        let db_lock = db_for_playlist_add.lock().unwrap();
        let tracks = db_lock.get_all_tracks().unwrap_or_default();
        let playlists = db_lock.get_playlists().unwrap_or_default();
        if track_index < 0 || playlist_index < 0 {
            ui.set_player_state_label("Select a track and playlist".into());
            return;
        }
        if let (Some(track), Some(playlist)) = (
            tracks.get(track_index as usize),
            playlists.get(playlist_index as usize),
        ) {
            if db_lock.add_track_to_playlist(playlist.id, track.id).is_ok() {
                ui.set_player_state_label("Added to playlist".into());
            }
        }
    });

    let db_for_playlist_load = Arc::clone(&db);
    let player_for_playlist_load = Arc::clone(&player);
    let session_for_playlist_load = Arc::clone(&active_session_token);
    let entry_for_playlist_load = Arc::clone(&active_playing_queue_entry_id);
    let ui_handle_playlist_load = ui.as_weak();
    ui.on_load_playlist_clicked(move || {
        let ui = match ui_handle_playlist_load.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let playlist_index = ui.get_selected_playlist_index();
        if playlist_index < 0 {
            ui.set_player_state_label("Select a playlist".into());
            return;
        }
        if let Some(token) = session_for_playlist_load.lock().unwrap().take() {
            player_for_playlist_load.stop(token);
        }
        *entry_for_playlist_load.lock().unwrap() = None;
        let db_lock = db_for_playlist_load.lock().unwrap();
        let playlists = db_lock.get_playlists().unwrap_or_default();
        let playlist = match playlists.get(playlist_index as usize) {
            Some(playlist) => playlist,
            None => return,
        };
        let tracks = db_lock.get_playlist_tracks(playlist.id).unwrap_or_default();
        let queue = tracks.into_iter().enumerate().map(|(position, track)| QueueEntry {
            queue_entry_id: Uuid::new_v4(),
            track_id: track.id,
            position: position as i32,
        }).collect::<Vec<_>>();
        if db_lock.save_queue(&queue).is_ok() {
            drop(db_lock);
            refresh_queue_list(&ui, &db_for_playlist_load);
            ui.set_selected_queue_index(-1);
            ui.set_playing_queue_index(-1);
            ui.set_player_state_label("Playlist loaded into queue".into());
        }
    });

    let db_for_next = Arc::clone(&db);
    let ui_handle_next = ui.as_weak();
    ui.on_next_clicked(move || {
        let ui = match ui_handle_next.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let queue = db_for_next.lock().unwrap().get_queue().unwrap_or_default();
        if queue.is_empty() {
            return;
        }
        let base = if ui.get_playing_queue_index() >= 0 {
            ui.get_playing_queue_index()
        } else {
            ui.get_selected_queue_index()
        };
        let next = if base < 0 { 0 } else { base + 1 };
        if (next as usize) < queue.len() {
            ui.set_selected_queue_index(next);
            ui.invoke_play_clicked();
        }
    });

    let db_for_previous = Arc::clone(&db);
    let ui_handle_previous = ui.as_weak();
    ui.on_previous_clicked(move || {
        let ui = match ui_handle_previous.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let queue = db_for_previous.lock().unwrap().get_queue().unwrap_or_default();
        if queue.is_empty() {
            return;
        }
        let base = if ui.get_playing_queue_index() >= 0 {
            ui.get_playing_queue_index()
        } else {
            ui.get_selected_queue_index()
        };
        let previous = if base < 0 { return; } else { base - 1 };
        if previous >= 0 {
            ui.set_selected_queue_index(previous);
            ui.invoke_play_clicked();
        }
    });

    let db_for_remove_queue = Arc::clone(&db);
    let player_for_remove_queue = Arc::clone(&player);
    let session_for_remove_queue = Arc::clone(&active_session_token);
    let entry_for_remove_queue = Arc::clone(&active_playing_queue_entry_id);
    let ui_handle_remove_queue = ui.as_weak();
    ui.on_remove_queue_clicked(move || {
        let ui = match ui_handle_remove_queue.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let selected = ui.get_selected_queue_index();
        if selected < 0 {
            return;
        }
        let mut queue = db_for_remove_queue.lock().unwrap().get_queue().unwrap_or_default();
        if (selected as usize) >= queue.len() {
            return;
        }
        let removed = queue.remove(selected as usize);
        for (position, entry) in queue.iter_mut().enumerate() {
            entry.position = position as i32;
        }
        if *entry_for_remove_queue.lock().unwrap() == Some(removed.queue_entry_id) {
            if let Some(token) = session_for_remove_queue.lock().unwrap().take() {
                player_for_remove_queue.stop(token);
            }
            *entry_for_remove_queue.lock().unwrap() = None;
            ui.set_playing_queue_index(-1);
        }
        if db_for_remove_queue.lock().unwrap().save_queue(&queue).is_ok() {
            refresh_queue_list(&ui, &db_for_remove_queue);
            ui.set_selected_queue_index(-1);
        }
    });

    let db_for_add = Arc::clone(&db);
    let ui_handle_add = ui.as_weak();
    ui.on_add_to_queue_clicked(move || {
        let ui = match ui_handle_add.upgrade() {
            Some(u) => u,
            None => return,
        };
        let idx = ui.get_selected_track_index();
        let db_lock = db_for_add.lock().unwrap();
        let tracks = db_lock.get_all_tracks().unwrap_or_default();
        if let Some(track) = tracks.get(idx as usize) {
            let mut current_queue = db_lock.get_queue().unwrap_or_default();
            let new_entry = QueueEntry {
                queue_entry_id: Uuid::new_v4(),
                track_id: track.id,
                position: current_queue.len() as i32,
            };
            current_queue.push(new_entry);
            let _ = db_lock.save_queue(&current_queue);
            drop(db_lock);
            refresh_queue_list(&ui, &db_for_add);
        }
    });

    let db_for_play = Arc::clone(&db);
    let player_for_play = Arc::clone(&player);
    let ui_handle_play = ui.as_weak();
    let manual_stopped_for_play = Arc::clone(&manual_stopped);
    let session_token_for_play = Arc::clone(&active_session_token);
    let active_entry_for_play = Arc::clone(&active_playing_queue_entry_id);

    ui.on_play_clicked(move || {
        let ui = match ui_handle_play.upgrade() {
            Some(u) => u,
            None => return,
        };
        let selection_changed = ui.get_selected_queue_index() != ui.get_playing_queue_index();
        match player_for_play.get_state() {
            PlayerState::Playing if !selection_changed => {
                if let Some(token) = *session_token_for_play.lock().unwrap() {
                    player_for_play.pause(token);
                    return;
                }
            }
            PlayerState::Paused if !selection_changed => {
                if let Some(token) = *session_token_for_play.lock().unwrap() {
                    player_for_play.resume(token);
                    return;
                }
            }
            _ => {}
        }
        manual_stopped_for_play.store(false, Ordering::Release);

        let (target_source, target_id, target_queue_entry_id) = {
            let db_lock = db_for_play.lock().unwrap();
            let queue_entries = db_lock.get_queue().unwrap_or_default();
            let all_tracks = db_lock.get_all_tracks().unwrap_or_default();

            if !queue_entries.is_empty() {
                let qidx = ui.get_selected_queue_index();
                let target_qidx = if qidx >= 0 && (qidx as usize) < queue_entries.len() { qidx as usize } else { 0 };
                let entry = &queue_entries[target_qidx];
                let track = all_tracks.iter().find(|t| t.id == entry.track_id).cloned();
                match track {
                    Some(t) => (t.source, t.id, entry.queue_entry_id),
                    None => return,
                }
            } else {
                let lib_idx = ui.get_selected_track_index();
                if lib_idx >= 0 {
                    if let Some(track) = all_tracks.get(lib_idx as usize) {
                        (track.source.clone(), track.id, Uuid::new_v4())
                    } else {
                        return;
                    }
                } else {
                    ui.set_player_state_label("No track selected".into());
                    return;
                }
            }
        };

        let session_token = Uuid::new_v4();
        *session_token_for_play.lock().unwrap() = Some(session_token);
        *active_entry_for_play.lock().unwrap() = Some(target_queue_entry_id);

        ui.set_player_state_label("Loading".into());
        if let Err(e) = player_for_play.play(target_source, target_id, target_queue_entry_id, session_token) {
            eprintln!("Playback error: {}", e);
            ui.set_player_state_label("Error".into());
        }
    });

    let player_for_seek = Arc::clone(&player);
    let session_for_seek = Arc::clone(&active_session_token);
    let last_seek_at_for_handler = Arc::clone(&last_seek_at);
    ui.on_seek_clicked(move |position| {
        *last_seek_at_for_handler.lock().unwrap() = Some(Instant::now());
        if let Some(token) = *session_for_seek.lock().unwrap() {
            player_for_seek.seek(position as f64, token);
        }
    });

    let player_for_stop = Arc::clone(&player);
    let ui_handle_stop = ui.as_weak();
    let manual_stopped_for_stop = Arc::clone(&manual_stopped);
    let session_token_for_stop = Arc::clone(&active_session_token);
    let active_entry_for_stop = Arc::clone(&active_playing_queue_entry_id);
    ui.on_stop_clicked(move || {
        manual_stopped_for_stop.store(true, Ordering::Release);
        let token = session_token_for_stop.lock().unwrap().take();
        *active_entry_for_stop.lock().unwrap() = None;
        if let Some(t) = token {
            player_for_stop.stop(t);
        }
        if let Some(ui) = ui_handle_stop.upgrade() {
            ui.set_player_state_label("Idle".into());
            ui.set_playing_queue_index(-1);
        }
    });

    let player_for_poll = Arc::clone(&player);
    let db_for_poll = Arc::clone(&db);
    let ui_handle_poll = ui.as_weak();
    let manual_stopped_for_poll = Arc::clone(&manual_stopped);
    let session_token_for_poll = Arc::clone(&active_session_token);
    let active_entry_for_poll = Arc::clone(&active_playing_queue_entry_id);
    let last_seek_at_for_poll = Arc::clone(&last_seek_at);
    let player_for_adv = Arc::clone(&player);

    std::thread::spawn(move || {
        let mut last_persisted_position = u64::MAX;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(100));
            if ui_handle_poll.upgrade().is_none() {
                break;
            }

            let events = player_for_poll.poll_events();
            for ev in events {
                match ev {
                    PlayerEvent::SessionStarted { session_token, track_id, queue_entry_id } => {
                        let active_token = *session_token_for_poll.lock().unwrap();
                        if Some(session_token) != active_token {
                            continue;
                        }
                        *active_entry_for_poll.lock().unwrap() = Some(queue_entry_id);

                        let (title, artist, qpos) = {
                            let db_l = db_for_poll.lock().unwrap();
                            let tracks = db_l.get_all_tracks().unwrap_or_default();
                            let queue_entries = db_l.get_queue().unwrap_or_default();
                            let track = tracks.iter().find(|t| t.id == track_id);
                            
                            let t_title = track.map(|t| t.title.clone()).unwrap_or_default();
                            let t_artist = track.map(|t| t.artist.clone()).unwrap_or_default();
                            let _ = db_l.set_state_value("current_track_id", &track_id.to_string());

                            let qpos = queue_entries.iter()
                                .position(|e| e.queue_entry_id == queue_entry_id)
                                .map(|p| p as i32)
                                .unwrap_or(-1);

                            (t_title, t_artist, qpos)
                        };

                        let ui_weak = ui_handle_poll.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = ui_weak.upgrade() {
                                ui.set_current_track_title(title.into());
                                ui.set_current_track_artist(artist.into());
                                ui.set_playing_queue_index(qpos);
                                ui.set_selected_queue_index(qpos);
                                ui.set_player_state_label("Playing".into());
                            }
                        });
                    }
                    PlayerEvent::Paused { session_token } => {
                        if Some(session_token) != *session_token_for_poll.lock().unwrap() { continue; }
                        let ui_weak = ui_handle_poll.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = ui_weak.upgrade() {
                                ui.set_player_state_label("Paused".into());
                            }
                        });
                    }
                    PlayerEvent::Resumed { session_token } => {
                        if Some(session_token) != *session_token_for_poll.lock().unwrap() { continue; }
                        let ui_weak = ui_handle_poll.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = ui_weak.upgrade() {
                                ui.set_player_state_label("Playing".into());
                            }
                        });
                    }
                    PlayerEvent::Stopped { session_token } | PlayerEvent::SessionTerminated { session_token } => {
                        let mut active_token_lock = session_token_for_poll.lock().unwrap();
                        if Some(session_token) == *active_token_lock {
                            *active_token_lock = None;
                            *active_entry_for_poll.lock().unwrap() = None;
                        }
                    }
                    PlayerEvent::PlaybackFailed { session_token, error_message: _ } => {
                        if Some(session_token) != *session_token_for_poll.lock().unwrap() { continue; }
                        let ui_weak = ui_handle_poll.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = ui_weak.upgrade() {
                                ui.set_player_state_label("Error".into());
                            }
                        });
                    }
                    PlayerEvent::NaturalEof { session_token, queue_entry_id } => {
                        if Some(session_token) != *session_token_for_poll.lock().unwrap() { continue; }
                        if !manual_stopped_for_poll.load(Ordering::Acquire) {
                            let db_l2 = db_for_poll.lock().unwrap();
                            let q_entries = db_l2.get_queue().unwrap_or_default();
                            let a_tracks = db_l2.get_all_tracks().unwrap_or_default();
                            drop(db_l2);

                            if let Some(current_idx) = q_entries.iter().position(|e| e.queue_entry_id == queue_entry_id) {
                                if current_idx + 1 < q_entries.len() {
                                    let next_entry = &q_entries[current_idx + 1];
                                    if let Some(t) = a_tracks.iter().find(|tr| tr.id == next_entry.track_id) {
                                        let new_token = Uuid::new_v4();
                                        *session_token_for_poll.lock().unwrap() = Some(new_token);
                                        *active_entry_for_poll.lock().unwrap() = Some(next_entry.queue_entry_id);
                                        let _ = player_for_adv.play(t.source.clone(), t.id, next_entry.queue_entry_id, new_token);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            let pos = player_for_poll.get_position_secs();
            let duration = player_for_poll.get_duration_secs().unwrap_or(0);
            let seeking = last_seek_at_for_poll.lock().unwrap()
                .as_ref()
                .map(|last| last.elapsed() < Duration::from_millis(500))
                .unwrap_or(false);
            if !seeking && pos != last_persisted_position {
                if let Ok(db_l) = db_for_poll.lock() {
                    let _ = db_l.set_state_value("position_secs", &pos.to_string());
                }
                last_persisted_position = pos;
            }
            let ui_weak_tick = ui_handle_poll.clone();
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(ui) = ui_weak_tick.upgrade() {
                    ui.set_duration_secs(duration as f32);
                    ui.set_is_seeking(seeking);
                    let display_pos = if seeking {
                        ui.get_playback_position_secs().max(0.0) as u64
                    } else {
                        ui.set_playback_position_secs(pos as f32);
                        pos
                    };
                    ui.set_progress_label(format!(
                        "{}:{:02} / {}:{:02}",
                        display_pos / 60, display_pos % 60, duration / 60, duration % 60
                    ).into());
                }
            });
        }
    });

    ui.run()?;
    Ok(())
}

fn refresh_track_list(ui: &MainWindow, db: &Arc<Mutex<LibraryDatabase>>) {
    let db_lock = db.lock().unwrap();
    let initial_tracks = db_lock.get_all_tracks().unwrap_or_default();
    let mut slint_tracks = Vec::new();
    for t in &initial_tracks {
        let dur = t.duration_secs.unwrap_or(0);
        slint_tracks.push(TrackData {
            id: t.id.to_string().into(),
            title: t.title.clone().into(),
            artist: t.artist.clone().into(),
            album: t.album.clone().unwrap_or_default().into(),
            duration: format!("{}:{:02}", dur / 60, dur % 60).into(),
        });
    }
    ui.set_track_list(slint::ModelRc::new(slint::VecModel::from(slint_tracks)));
}

fn refresh_playlist_list(ui: &MainWindow, db: &Arc<Mutex<LibraryDatabase>>) {
    let db_lock = db.lock().unwrap();
    let playlists = db_lock.get_playlists().unwrap_or_default();
    let rows = playlists.into_iter().map(|playlist| PlaylistData {
        id: playlist.id.to_string().into(),
        name: playlist.name.into(),
    }).collect::<Vec<_>>();
    ui.set_playlist_list(slint::ModelRc::new(slint::VecModel::from(rows)));
}

fn refresh_queue_list(ui: &MainWindow, db: &Arc<Mutex<LibraryDatabase>>) {
    let db_lock = db.lock().unwrap();
    let queue_entries = db_lock.get_queue().unwrap_or_default();
    let all_tracks = db_lock.get_all_tracks().unwrap_or_default();
    let mut slint_queue = Vec::new();
    for entry in queue_entries {
        if let Some(t) = all_tracks.iter().find(|tr| tr.id == entry.track_id) {
            let dur = t.duration_secs.unwrap_or(0);
            slint_queue.push(TrackData {
                id: t.id.to_string().into(),
                title: t.title.clone().into(),
                artist: t.artist.clone().into(),
                album: t.album.clone().unwrap_or_default().into(),
                duration: format!("{}:{:02}", dur / 60, dur % 60).into(),
            });
        }
    }
    ui.set_queue_list(slint::ModelRc::new(slint::VecModel::from(slint_queue)));
}

fn music_data_dir() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let base = if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
        PathBuf::from(xdg)
    } else if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home).join(".local").join("share")
    } else {
        return Err("Neither XDG_DATA_HOME nor HOME is set".into());
    };
    let dir = base.join("raptor-music");
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn walk_dir_and_import(dir: &std::path::Path, db: &mut LibraryDatabase) {
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk_dir_and_import(&path, db);
            } else if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                let ext_lower = ext.to_lowercase();
                if matches!(
                    ext_lower.as_str(),
                    "aac" | "aif" | "aiff" | "alac" | "caf" | "flac" | "m4a" |
                    "mp3" | "mp4" | "ogg" | "opus" | "wav"
                ) {
                    let metadata = match AudioDecoder::extract_metadata(&path) {
                        Ok(m) => m,
                        Err(_) => continue,
                    };
                    let stable_id = LibraryDatabase::generate_stable_track_id(&path, "local");
                    let track = Track {
                        id: stable_id,
                        title: metadata.title,
                        artist: metadata.artist,
                        album: metadata.album,
                        duration_secs: metadata.duration_secs,
                        source: PlaybackSource::LocalFile { path: path.clone() },
                    };
                    let _ = db.upsert_track(&track);
                }
            }
        }
    }
}
