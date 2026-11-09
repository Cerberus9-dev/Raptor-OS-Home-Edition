slint::include_modules!();

mod profile_import;

#[derive(Clone, Debug)]
struct AudiusArtist { id: String, name: String, handle: String }

#[derive(Clone, Debug)]
struct AudiusArtistProfile {
    name: String,
    handle: String,
    bio: String,
    follower_count: u64,
    track_count: u64,
    tracks: Vec<Track>,
}

use raptor_audio::player::AudioPlayer;
use raptor_audio::decoder::AudioDecoder;
use raptor_library::{LibraryDatabase, QueueEntry};
use raptor_core::models::{Track, PlaybackSource, PlayerState, PlayerEvent};
use std::sync::{Arc, Mutex};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};
use uuid::Uuid;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let db_path = music_data_dir()?.join("raptor_music.db");
    let db = Arc::new(Mutex::new(LibraryDatabase::new(&db_path)?));
    let player = Arc::new(AudioPlayer::new());

    let ui = MainWindow::new()?;
    let visible_track_ids = Arc::new(Mutex::new(
        db.lock().unwrap().get_all_tracks().unwrap_or_default()
            .into_iter().filter(is_local_track).map(|track| track.id).collect::<Vec<_>>()
    ));
    let selected_track_id: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    refresh_track_list(&ui, &db);
    refresh_queue_list(&ui, &db);
    refresh_playlist_list(&ui, &db);

    let manual_stopped = Arc::new(AtomicBool::new(false));
    let active_session_token: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    let active_playing_queue_entry_id: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    let last_seek_at: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));
    let online_tracks: Arc<Mutex<Vec<Track>>> = Arc::new(Mutex::new(Vec::new()));
    let online_artists: Arc<Mutex<Vec<AudiusArtist>>> = Arc::new(Mutex::new(Vec::new()));
    let online_search_generation = Arc::new(AtomicU64::new(0));

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
    let visible_ids_for_scan = Arc::clone(&visible_track_ids);
    let selected_id_for_scan = Arc::clone(&selected_track_id);

    ui.on_scan_directory_clicked(move || {
        if let Some(folder) = rfd::FileDialog::new().pick_folder() {
            let db_path_inner = db_path_clone.clone();
            let ui_weak = ui_handle_scan.clone();
            let visible_ids = Arc::clone(&visible_ids_for_scan);
            let selected_id = Arc::clone(&selected_id_for_scan);
            std::thread::spawn(move || {
                if let Ok(mut worker_db) = LibraryDatabase::new(db_path_inner) {
                    walk_dir_and_import(&folder, &mut worker_db);
                    let updated_tracks = worker_db.get_all_tracks().unwrap_or_default()
                        .into_iter().filter(is_local_track).collect::<Vec<_>>();
                    *visible_ids.lock().unwrap() = updated_tracks.iter().map(|track| track.id).collect();
                    *selected_id.lock().unwrap() = None;
                    let new_slint_tracks = tracks_to_slint(&updated_tracks);

                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_search_query("".into());
                            ui.set_selected_track_index(-1);
                            ui.set_track_list(slint::ModelRc::new(slint::VecModel::from(new_slint_tracks)));
                        }
                    });
                }
            });
        }
    });

    let ui_handle_profile_import = ui.as_weak();
    ui.on_import_profile_clicked(move || {
        let selected_files = rfd::FileDialog::new()
            .add_filter("Profile export files", &["json"])
            .pick_files();
        let files = match selected_files {
            Some(files) if !files.is_empty() => files,
            _ => return,
        };
        let ui_weak = ui_handle_profile_import.clone();
        std::thread::spawn(move || {
            let mut combined = profile_import::ImportedProfile::default();
            let mut imported_files = 0usize;
            let mut errors = Vec::new();
            for path in files {
                match std::fs::read_to_string(&path) {
                    Ok(payload) => match profile_import::parse_profile_export(&payload) {
                        Ok(mut part) => {
                            if combined.source.is_empty() { combined.source = part.source.clone(); }
                            if combined.display_name.is_none() { combined.display_name = part.display_name.take(); }
                            if combined.username.is_none() { combined.username = part.username.take(); }
                            if combined.biography.is_none() { combined.biography = part.biography.take(); }
                            if combined.avatar_url.is_none() { combined.avatar_url = part.avatar_url.take(); }
                            combined.playlists.append(&mut part.playlists);
                            combined.saved_tracks.append(&mut part.saved_tracks);
                            combined.followed_artists.append(&mut part.followed_artists);
                            combined.listening_history.append(&mut part.listening_history);
                            imported_files += 1;
                        }
                        Err(error) => errors.push(format!("{}: {}", path.file_name().unwrap_or_default().to_string_lossy(), error)),
                    },
                    Err(error) => errors.push(format!("{}: {}", path.file_name().unwrap_or_default().to_string_lossy(), error)),
                }
            }
            let summary = combined.summary();
            let status = if imported_files == 0 {
                format!("No supported profile data imported. {}", errors.join(" · "))
            } else {
                let identity = combined.display_name.as_deref()
                    .or(combined.username.as_deref()).unwrap_or("Profile");
                let mut message = format!(
                    "{} · {} file(s) · {} playlist(s) / {} playlist tracks · {} saved tracks · {} followed artists · {} listening events · avatar {}. Preview only; nothing has been added to your library yet.",
                    identity, imported_files, summary.playlists, summary.playlist_tracks,
                    summary.saved_tracks, summary.followed_artists, summary.listening_events,
                    if summary.has_profile_image { "available" } else { "not included" }
                );
                if !errors.is_empty() {
                    message.push_str(&format!(" Skipped {} file(s): {}", errors.len(), errors.join(" · ")));
                }
                message
            };
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(ui) = ui_weak.upgrade() {
                    ui.set_profile_import_status(status.into());
                }
            });
        });
    });

    let db_for_search = Arc::clone(&db);
    let visible_ids_for_search = Arc::clone(&visible_track_ids);
    let selected_id_for_search = Arc::clone(&selected_track_id);
    let online_tracks_for_search = Arc::clone(&online_tracks);
    let online_artists_for_search = Arc::clone(&online_artists);
    let online_generation_for_search = Arc::clone(&online_search_generation);
    let ui_handle_search = ui.as_weak();
    ui.on_search_changed(move |query| {
        let ui = match ui_handle_search.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let query = query.to_string();
        let request_generation = online_generation_for_search.fetch_add(1, Ordering::AcqRel) + 1;

        let all_tracks = db_for_search.lock().unwrap().get_all_tracks().unwrap_or_default()
            .into_iter().filter(is_local_track).collect::<Vec<_>>();
        let needle = query.trim().to_lowercase();
        let tokens = needle.split_whitespace().collect::<Vec<_>>();
        let filtered = all_tracks.into_iter().filter(|track| {
            if tokens.is_empty() {
                return true;
            }
            let haystack = format!(
                "{} {} {}",
                track.title,
                track.artist,
                track.album.as_deref().unwrap_or("")
            ).to_lowercase();
            tokens.iter().all(|token| haystack.contains(token))
        }).collect::<Vec<_>>();

        *visible_ids_for_search.lock().unwrap() = filtered.iter().map(|track| track.id).collect();
        *selected_id_for_search.lock().unwrap() = None;
        ui.set_selected_track_index(-1);
        ui.set_selected_online_track_index(-1);
        ui.set_track_list(slint::ModelRc::new(slint::VecModel::from(tracks_to_slint(&filtered))));

        // The Local Library is intentionally offline-only. Avoid catalog
        // requests while the user is browsing or filtering local files.
        if ui.get_active_view() != "discover" {
            *online_tracks_for_search.lock().unwrap() = Vec::new();
            *online_artists_for_search.lock().unwrap() = Vec::new();
            ui.set_online_artist_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_search_status("Online discovery is available in the Discover tab".into());
            return;
        }

        if query.trim().chars().count() < 2 {
            *online_tracks_for_search.lock().unwrap() = Vec::new();
            *online_artists_for_search.lock().unwrap() = Vec::new();
            ui.set_online_artist_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_search_status("Type at least 2 characters to search online".into());
            return;
        }

        ui.set_online_search_status("Searching…".into());
        let query_for_thread = query.trim().to_string();
        let sort_method = ui.get_online_sort_method().to_string();
        let ui_weak = ui_handle_search.clone();
        let online_tracks = Arc::clone(&online_tracks_for_search);
        let online_artists = Arc::clone(&online_artists_for_search);
        let generation = Arc::clone(&online_generation_for_search);
        std::thread::spawn(move || {
            // Debounce typing and discard stale responses so a slower network
            // response can never overwrite results for a newer search.
            std::thread::sleep(Duration::from_millis(450));
            if generation.load(Ordering::Acquire) != request_generation {
                return;
            }
            // Run track and artist discovery concurrently: the slower endpoint
            // must not add its full network timeout to the other result.
            let artist_query = query_for_thread.clone();
            let artist_sort_method = sort_method.clone();
            let artist_worker = std::thread::spawn(move || search_audius_artists(&artist_query, &artist_sort_method));
            let result = search_audius_tracks(&query_for_thread, &sort_method);
            let artist_result = artist_worker.join()
                .unwrap_or_else(|_| Err("Artist search worker stopped unexpectedly".to_string()));
            if generation.load(Ordering::Acquire) != request_generation {
                return;
            }

            match result {
                Ok(tracks) => {
                    let count = tracks.len();
                    *online_tracks.lock().unwrap() = tracks.clone();
                    let rows = tracks_to_slint(&tracks);
                    let artist_error = artist_result.is_err();
                    let artists = artist_result.unwrap_or_default();
                    *online_artists.lock().unwrap() = artists.clone();
                    let artist_count = artists.len();
                    let artist_rows = artists.iter().map(|artist| TrackData {
                        id: artist.id.clone().into(), title: artist.name.clone().into(),
                        artist: format!("@{}", artist.handle).into(), album: "Artist profile".into(), duration: "Open".into(),
                    }).collect::<Vec<_>>();
                    let mut status = format!("{count} tracks · {artist_count} artists");
                    if artist_error {
                        status.push_str(" · Some artist results are unavailable");
                    } else if count == 0 && artist_count == 0 {
                        status = "No matching tracks or artists found".to_string();
                    }
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(rows)));
                            ui.set_online_artist_list(slint::ModelRc::new(slint::VecModel::from(artist_rows)));
                            ui.set_online_search_status(status.into());
                        }
                    });
                }
                Err(_error) => {
                    *online_tracks.lock().unwrap() = Vec::new();
                    *online_artists.lock().unwrap() = Vec::new();
                    let status = "Online search is temporarily unavailable. Try again shortly.".to_string();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_online_track_list(slint::ModelRc::new(
                                slint::VecModel::from(Vec::<TrackData>::new())
                            ));
                            ui.set_online_artist_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
                            ui.set_online_search_status(status.into());
                        }
                    });
                }
            }
        });
    });

    let visible_ids_for_select = Arc::clone(&visible_track_ids);
    let selected_id_for_select = Arc::clone(&selected_track_id);
    let ui_handle_select = ui.as_weak();
    ui.on_track_selected(move |idx| {
        let id = visible_ids_for_select.lock().unwrap().get(idx as usize).copied();
        if let Some(id) = id {
            *selected_id_for_select.lock().unwrap() = Some(id);
            if let Some(ui) = ui_handle_select.upgrade() {
                ui.set_selected_track_index(idx);
                ui.set_selected_online_track_index(-1);
            }
        }
    });

    let online_tracks_for_select = Arc::clone(&online_tracks);
    let db_for_online_select = Arc::clone(&db);
    let selected_id_for_online_select = Arc::clone(&selected_track_id);
    let ui_handle_online_select = ui.as_weak();
    ui.on_online_track_selected(move |idx| {
        let track = online_tracks_for_select.lock().unwrap().get(idx as usize).cloned();
        if let Some(track) = track {
            let saved = db_for_online_select.lock().unwrap().upsert_track(&track).is_ok();
            if !saved {
                if let Some(ui) = ui_handle_online_select.upgrade() {
                    ui.set_player_state_label("Could not add online track to your library".into());
                }
                return;
            }
            *selected_id_for_online_select.lock().unwrap() = Some(track.id);
            if let Some(ui) = ui_handle_online_select.upgrade() {
                ui.set_selected_online_track_index(idx);
                ui.set_selected_track_index(-1);
                ui.set_player_state_label("Online track selected · Add selected to queue".into());
            }
        }
    });

    let artists_for_profile = Arc::clone(&online_artists);
    let tracks_for_profile = Arc::clone(&online_tracks);
    let generation_for_profile = Arc::clone(&online_search_generation);
    let ui_handle_profile = ui.as_weak();
    ui.on_artist_selected(move |idx| {
        let artist = artists_for_profile.lock().unwrap().get(idx as usize).cloned();
        let artist = match artist {
            Some(artist) => artist,
            None => return,
        };
        let request_generation = generation_for_profile.fetch_add(1, Ordering::AcqRel) + 1;
        if let Some(ui) = ui_handle_profile.upgrade() {
            ui.set_active_view("artist".into());
            ui.set_artist_profile_name(artist.name.clone().into());
            ui.set_artist_profile_handle(format!("@{}", artist.handle).into());
            ui.set_artist_profile_bio("Loading artist information…".into());
            ui.set_artist_profile_stats("Loading profile…".into());
            ui.set_artist_profile_status("Loading tracks…".into());
            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_selected_online_track_index(-1);
        }
        let ui_weak = ui_handle_profile.clone();
        let artists_tracks = Arc::clone(&tracks_for_profile);
        let generation = Arc::clone(&generation_for_profile);
        std::thread::spawn(move || {
            let result = fetch_audius_artist_profile(&artist);
            if generation.load(Ordering::Acquire) != request_generation {
                return;
            }
            match result {
                Ok(profile) => {
                    let tracks = profile.tracks.clone();
                    let rows = tracks_to_slint(&tracks);
                    *artists_tracks.lock().unwrap() = tracks;
                    let stats = format!("{} tracks · {} followers", profile.track_count, profile.follower_count);
                    let status = if rows.is_empty() {
                        "No playable tracks are available for this artist".to_string()
                    } else {
                        format!("{} tracks available", rows.len())
                    };
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_artist_profile_name(profile.name.into());
                            ui.set_artist_profile_handle(format!("@{}", profile.handle).into());
                            ui.set_artist_profile_bio(profile.bio.into());
                            ui.set_artist_profile_stats(stats.into());
                            ui.set_artist_profile_status(status.into());
                            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(rows)));
                        }
                    });
                }
                Err(_error) => {
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_artist_profile_bio("Artist information is temporarily unavailable.".into());
                            ui.set_artist_profile_stats("".into());
                            ui.set_artist_profile_status("Could not load this artist's tracks. Try again.".into());
                        }
                    });
                }
            }
        });
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
    let selected_id_for_playlist_add = Arc::clone(&selected_track_id);
    let ui_handle_playlist_add = ui.as_weak();
    ui.on_add_to_playlist_clicked(move || {
        let ui = match ui_handle_playlist_add.upgrade() {
            Some(ui) => ui,
            None => return,
        };
        let selected_id = *selected_id_for_playlist_add.lock().unwrap();
        let playlist_index = ui.get_selected_playlist_index();
        let db_lock = db_for_playlist_add.lock().unwrap();
        let tracks = db_lock.get_all_tracks().unwrap_or_default();
        let playlists = db_lock.get_playlists().unwrap_or_default();
        if selected_id.is_none() || playlist_index < 0 {
            ui.set_player_state_label("Select a track and playlist".into());
            return;
        }
        if let (Some(track), Some(playlist)) = (
            tracks.iter().find(|track| Some(track.id) == selected_id),
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
        let playing_index = ui.get_playing_queue_index();
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
            ui.set_player_state_label("Idle".into());
        } else if playing_index > selected {
            ui.set_playing_queue_index(playing_index - 1);
        }
        if db_for_remove_queue.lock().unwrap().save_queue(&queue).is_ok() {
            refresh_queue_list(&ui, &db_for_remove_queue);
            ui.set_selected_queue_index(-1);
        }
    });

    let db_for_add = Arc::clone(&db);
    let selected_id_for_queue_add = Arc::clone(&selected_track_id);
    let ui_handle_add = ui.as_weak();
    ui.on_add_to_queue_clicked(move || {
        let ui = match ui_handle_add.upgrade() {
            Some(u) => u,
            None => return,
        };
        let selected_id = *selected_id_for_queue_add.lock().unwrap();
        let db_lock = db_for_add.lock().unwrap();
        let tracks = db_lock.get_all_tracks().unwrap_or_default();
        if let Some(track) = tracks.iter().find(|track| Some(track.id) == selected_id) {
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
    let selected_id_for_play = Arc::clone(&selected_track_id);

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
                let selected_id = *selected_id_for_play.lock().unwrap();
                if let Some(track) = all_tracks.iter().find(|track| Some(track.id) == selected_id) {
                    (track.source.clone(), track.id, Uuid::new_v4())
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
                    // The slider owns the preview value while the user is dragging.
                    // Keep it until Seek is pressed; the backend's short seek window
                    // then protects the requested position while the decoder restarts.
                    let slider_editing = ui.get_is_seeking();
                    let display_pos = if seeking || slider_editing {
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

fn audius_flag(value: &serde_json::Value, key: &str, default: bool) -> bool {
    match value.get(key) {
        Some(serde_json::Value::Bool(flag)) => *flag,
        Some(serde_json::Value::String(flag)) => flag.eq_ignore_ascii_case("true"),
        _ => default,
    }
}

fn parse_audius_tracks(payload: &serde_json::Value) -> Result<Vec<Track>, String> {
    let rows = payload
        .get("data")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "Audius returned an unexpected search response".to_string())?;

    let mut tracks = Vec::new();
    for row in rows.iter().take(50) {
        // Do not display hidden, unavailable, gated, or non-streamable items as
        // playable results. The player repeats this provider check at playback.
        if !audius_flag(row, "is_streamable", false)
            || audius_flag(row, "is_unlisted", false)
            || audius_flag(row, "is_stream_gated", false)
            || !audius_flag(row, "is_available", true)
            || audius_flag(row, "is_delete", false)
        {
            continue;
        }

        let Some(provider_track_id) = row.get("id").and_then(serde_json::Value::as_str) else {
            continue;
        };
        if provider_track_id.is_empty()
            || !provider_track_id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
        {
            continue;
        }
        let Some(title) = row.get("title").and_then(serde_json::Value::as_str) else {
            continue;
        };
        let artist = row
            .get("user")
            .and_then(|user| user.get("name"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("Unknown artist");
        let album = row
            .get("album")
            .and_then(|album| album.get("title"))
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string);
        let duration = row
            .get("duration")
            .and_then(serde_json::Value::as_u64);

        let stable_id = Uuid::new_v5(
            &Uuid::NAMESPACE_URL,
            format!("raptor-music:audius:{provider_track_id}").as_bytes(),
        );
        tracks.push(Track {
            id: stable_id,
            title: title.to_string(),
            artist: artist.to_string(),
            album,
            duration_secs: duration,
            source: PlaybackSource::RemoteStream {
                provider_id: "audius".into(),
                provider_track_id: provider_track_id.to_string(),
            },
        });
    }
    Ok(tracks)
}

fn normalized_sort_method(value: &str) -> &'static str {
    match value {
        "popular" => "popular",
        "recent" => "recent",
        _ => "relevant",
    }
}

fn search_audius_artists(query: &str, sort_method: &str) -> Result<Vec<AudiusArtist>, String> {
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| format!("Could not initialize artist search: {error}"))?;
    let response = client.get("https://api.audius.co/v1/users/search")
        .query(&[("query", query), ("limit", "30"), ("offset", "0"), ("sort_method", normalized_sort_method(sort_method))])
        .send().and_then(|response| response.error_for_status())
        .map_err(|error| format!("Audius artist search failed: {error}"))?;
    let payload: serde_json::Value = response.json()
        .map_err(|error| format!("Audius returned unreadable artist results: {error}"))?;
    let data = payload.get("data").and_then(serde_json::Value::as_array)
        .ok_or_else(|| "Audius returned an unexpected artist search response".to_string())?;
    Ok(data.iter().filter_map(|entry| {
        let id = entry.get("id")?.as_str()?.to_string();
        let handle = entry.get("handle")?.as_str()?.to_string();
        let name = entry.get("name").and_then(serde_json::Value::as_str)
            .filter(|name| !name.trim().is_empty())
            .or_else(|| entry.get("handle").and_then(serde_json::Value::as_str))?.to_string();
        if id.is_empty()
            || !id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
            || handle.is_empty()
            || handle.contains('/')
        {
            return None;
        }
        Some(AudiusArtist { id, name, handle })
    }).collect())
}

fn fetch_audius_artist_profile(artist: &AudiusArtist) -> Result<AudiusArtistProfile, String> {
    if artist.id.is_empty()
        || !artist.id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return Err("Invalid artist identifier".to_string());
    }

    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| format!("Could not initialize artist profile request: {error}"))?;

    let profile_response = client
        .get(format!("https://api.audius.co/v1/users/{}", artist.id))
        .send()
        .and_then(|response| response.error_for_status())
        .map_err(|error| format!("Artist profile request failed: {error}"))?;
    let profile_payload: serde_json::Value = profile_response
        .json()
        .map_err(|error| format!("Artist profile response was unreadable: {error}"))?;
    let data = profile_payload
        .get("data")
        .filter(|value| value.is_object())
        .ok_or_else(|| "Artist profile response had an unexpected shape".to_string())?;

    let name = data
        .get("name")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&artist.name)
        .to_string();
    let handle = data
        .get("handle")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&artist.handle)
        .to_string();
    let bio = data
        .get("bio")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();
    let follower_count = data
        .get("follower_count")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);
    let track_count = data
        .get("track_count")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(0);

    let tracks_response = client
        .get(format!("https://api.audius.co/v1/users/{}/tracks", artist.id))
        .query(&[
            ("limit", "50"),
            ("offset", "0"),
            ("filter_tracks", "public"),
            ("gate_condition", "ungated"),
            ("sort_method", "plays"),
            ("sort_direction", "desc"),
        ])
        .send()
        .and_then(|response| response.error_for_status())
        .map_err(|error| format!("Artist tracks request failed: {error}"))?;
    let tracks_payload: serde_json::Value = tracks_response
        .json()
        .map_err(|error| format!("Artist tracks response was unreadable: {error}"))?;
    let mut tracks = parse_audius_tracks(&tracks_payload)?;
    for track in &mut tracks {
        if track.artist == "Unknown artist" {
            track.artist = name.clone();
        }
    }

    Ok(AudiusArtistProfile {
        name,
        handle,
        bio,
        follower_count,
        track_count,
        tracks,
    })
}

fn search_audius_tracks(query: &str, sort_method: &str) -> Result<Vec<Track>, String> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(Vec::new());
    }

    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.17")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| format!("Could not initialize online search: {error}"))?;

    let response = client
        .get("https://api.audius.co/v1/tracks/search")
        .query(&[
            ("query", query),
            ("limit", "50"),
            ("offset", "0"),
            ("sort_method", normalized_sort_method(sort_method)),
            ("app_name", "RaptorMusic"),
        ])
        .send()
        .and_then(|response| response.error_for_status())
        .map_err(|error| format!("Audius search request failed: {error}"))?;

    let payload: serde_json::Value = response
        .json()
        .map_err(|error| format!("Audius returned unreadable search results: {error}"))?;
    parse_audius_tracks(&payload)
}

#[cfg(test)]
mod audius_search_tests {
    use super::*;

    #[test]
    fn online_search_keeps_only_public_streamable_tracks() {
        let payload = serde_json::json!({
            "data": [
                {
                    "id": "track_public_01",
                    "title": "Example Song",
                    "user": { "name": "Example Artist" },
                    "album": { "title": "Example Album" },
                    "genre": "Electronic",
                    "duration": 187,
                    "is_streamable": true,
                    "is_unlisted": false,
                    "is_stream_gated": false,
                    "is_available": true,
                    "is_delete": false
                },
                {
                    "id": "track_hidden_02",
                    "title": "Hidden Song",
                    "is_streamable": true,
                    "is_unlisted": true
                },
                {
                    "id": "track_gated_03",
                    "title": "Gated Song",
                    "is_streamable": true,
                    "is_stream_gated": true
                },
                {
                    "id": "track_unavailable_04",
                    "title": "Unavailable Song",
                    "is_streamable": true,
                    "is_available": false
                },
                {
                    "id": "track_nonstreamable_05",
                    "title": "Non-streamable Song",
                    "is_streamable": false
                },
                {
                    "id": "invalid/id",
                    "title": "Invalid Identifier",
                    "is_streamable": true
                }
            ]
        });

        let tracks = parse_audius_tracks(&payload).expect("valid provider response");
        assert_eq!(tracks.len(), 1);
        let track = &tracks[0];
        assert_eq!(track.title, "Example Song");
        assert_eq!(track.artist, "Example Artist");
        assert_eq!(track.album.as_deref(), Some("Example Album"));
        assert_eq!(track.duration_secs, Some(187));
        assert_eq!(
            track.source,
            PlaybackSource::RemoteStream {
                provider_id: "audius".into(),
                provider_track_id: "track_public_01".into(),
            }
        );

        let repeated = parse_audius_tracks(&payload).expect("same provider response");
        assert_eq!(track.id, repeated[0].id, "online IDs must remain stable across searches");
    }

    #[test]
    fn unexpected_online_search_shape_is_reported() {
        let error = parse_audius_tracks(&serde_json::json!({"results": []}))
            .expect_err("unexpected API shape must not look like an empty successful search");
        assert!(error.contains("unexpected search response"));
    }
}

fn tracks_to_slint(tracks: &[Track]) -> Vec<TrackData> {
    tracks.iter().map(|track| {
        let duration = track.duration_secs.unwrap_or(0);
        TrackData {
            id: track.id.to_string().into(),
            title: track.title.clone().into(),
            artist: track.artist.clone().into(),
            album: track.album.clone().unwrap_or_default().into(),
            duration: format!("{}:{:02}", duration / 60, duration % 60).into(),
        }
    }).collect()
}

fn is_local_track(track: &Track) -> bool {
    matches!(&track.source, PlaybackSource::LocalFile { .. })
}

fn refresh_track_list(ui: &MainWindow, db: &Arc<Mutex<LibraryDatabase>>) {
    let db_lock = db.lock().unwrap();
    let initial_tracks = db_lock.get_all_tracks().unwrap_or_default()
        .into_iter().filter(is_local_track).collect::<Vec<_>>();
    ui.set_track_list(slint::ModelRc::new(slint::VecModel::from(tracks_to_slint(&initial_tracks))));
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
    let mut visited_directories = HashSet::new();
    walk_dir_and_import_inner(dir, db, &mut visited_directories);
}

fn walk_dir_and_import_inner(
    dir: &std::path::Path,
    db: &mut LibraryDatabase,
    visited_directories: &mut HashSet<PathBuf>,
) {
    // Directory symlinks are followed by Path::is_dir(). Track canonical
    // locations so a Music folder containing a link to one of its parents
    // cannot recurse forever or import the same directory repeatedly.
    let canonical_dir = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    if !visited_directories.insert(canonical_dir) {
        return;
    }

    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            walk_dir_and_import_inner(&path, db, visited_directories);
            continue;
        }

        let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
            continue;
        };
        let ext_lower = ext.to_ascii_lowercase();
        if !matches!(
            ext_lower.as_str(),
            "aac" | "aif" | "aiff" | "alac" | "caf" | "flac" | "m4a" |
            "mp3" | "mp4" | "ogg" | "opus" | "wav"
        ) {
            continue;
        }

        let metadata = match AudioDecoder::extract_metadata(&path) {
            Ok(metadata) => metadata,
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

#[cfg(test)]
mod local_library_visibility_tests {
    use super::*;

    fn sample_track(source: PlaybackSource) -> Track {
        Track {
            id: Uuid::new_v4(),
            title: "Sample".into(),
            artist: "Artist".into(),
            album: None,
            duration_secs: Some(60),
            source,
        }
    }

    #[test]
    fn local_library_view_excludes_remote_catalog_tracks() {
        let local = sample_track(PlaybackSource::LocalFile { path: PathBuf::from("/music/local.flac") });
        let remote = sample_track(PlaybackSource::RemoteStream {
            provider_id: "audius".into(), provider_track_id: "remote-123".into(),
        });
        assert!(is_local_track(&local));
        assert!(!is_local_track(&remote));
    }
}
