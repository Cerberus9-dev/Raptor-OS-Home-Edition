slint::include_modules!();

mod profile_import;
mod provider_auth;
mod token_store;
mod callback_listener;
mod apple_music_auth;

fn refresh_provider_tokens_if_needed(
    provider: provider_auth::OAuthProvider,
    provider_key: &str,
    bundle: token_store::StoredTokenBundle,
) -> Result<(), String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default().as_secs();
    let expires_at = bundle.saved_at_unix.saturating_add(bundle.tokens.expires_in);
    if bundle.saved_at_unix > 0 && now.saturating_add(60) < expires_at {
        return Ok(());
    }
    let refresh_token = bundle.tokens.refresh_token.as_deref()
        .ok_or_else(|| "The saved access token has expired; disconnect and reconnect this account".to_string())?;
    let (_, pending) = provider_auth::begin_authorization(provider, None)
        .map_err(|error| format!("Could not prepare token refresh: {error}"))?;
    let mut refreshed = provider_auth::refresh_access_token(&pending, refresh_token)?;
    if refreshed.refresh_token.is_none() {
        refreshed.refresh_token = Some(refresh_token.to_owned());
    }
    token_store::save_tokens(provider_key, &refreshed)?;
    Ok(())
}

fn restore_provider_connections(ui: slint::Weak<MainWindow>) {
    std::thread::spawn(move || {
        let providers = [
            ("Spotify", "spotify", provider_auth::OAuthProvider::Spotify),
            ("YouTube account", "youtube", provider_auth::OAuthProvider::YoutubeData),
        ];
        let mut connected = Vec::new();
        let mut needs_attention = Vec::new();
        if token_store::load_music_user_token().is_ok() {
            connected.push("Apple Music");
        }
        for (label, key, provider) in providers {
            if let Ok(bundle) = token_store::load_token_bundle(key) {
                match refresh_provider_tokens_if_needed(provider, key, bundle) {
                    Ok(()) => connected.push(label),
                    Err(error) => needs_attention.push(format!("{label}: {error}")),
                }
            }
        }
        let mut status = if connected.is_empty() {
            "No active music-service connections".to_string()
        } else {
            format!("Connected accounts: {}", connected.join(", "))
        };
        if !needs_attention.is_empty() {
            status.push_str(&format!(" · {}", needs_attention.join(" · ")));
        }
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = ui.upgrade() {
                ui.set_provider_connection_status(status.into());
            }
        });
    });
}

fn start_provider_connection(
    provider: provider_auth::OAuthProvider,
    ui: slint::Weak<MainWindow>,
    db: Arc<Mutex<LibraryDatabase>>,
) {
    std::thread::spawn(move || {
        let provider_key = match provider {
            provider_auth::OAuthProvider::Spotify => "spotify",
            provider_auth::OAuthProvider::Tidal => "tidal",
            provider_auth::OAuthProvider::YoutubeData => "youtube",
        };
        let result = (|| -> Result<String, String> {
            let (authorization_url, pending) = provider_auth::begin_authorization(provider, None)
                .map_err(|error| error.to_string())?;
            // Bind first so the provider cannot redirect before the receiver is listening.
            let receiver = callback_listener::CallbackListener::bind(&pending)?;
            std::process::Command::new("gio").arg("open")
                .arg(authorization_url.as_str())
                .spawn()
                .map_err(|_| "Could not open the system browser for provider sign-in".to_string())?;
            let code = receiver.wait_for_code(&pending, Duration::from_secs(180))?;
            let tokens = provider_auth::exchange_authorization_code(&pending, &code)?;
            token_store::save_tokens(provider_key, &tokens)?;
            match provider {
                provider_auth::OAuthProvider::Spotify | provider_auth::OAuthProvider::Tidal | provider_auth::OAuthProvider::YoutubeData => {
                    let provider_profile = provider_auth::fetch_provider_profile(provider, &tokens.access_token)?;
                    let mut provider_warnings = Vec::new();
                    let provider_playlists = provider_auth::collect_optional_provider_section(
                        "Playlists",
                        provider_auth::fetch_provider_playlists(provider, &tokens.access_token),
                        &mut provider_warnings,
                    );
                    let mut imported = profile_import::ImportedProfile {
                        source: match provider {
                            provider_auth::OAuthProvider::YoutubeData => "YouTube Data API account".into(),
                            provider_auth::OAuthProvider::Tidal => "TIDAL account".into(),
                            provider_auth::OAuthProvider::Spotify => "Spotify account".into(),
                        },
                        display_name: Some(provider_profile.display_name.clone()),
                        username: Some(provider_profile.id.clone()),
                        avatar_url: provider_profile.avatar_url.clone(),
                        ..profile_import::ImportedProfile::default()
                    };
                    if provider == provider_auth::OAuthProvider::Spotify {
                        let extras = provider_auth::fetch_spotify_profile_extras(&tokens.access_token);
                        provider_warnings.extend(extras.warnings);
                        imported.saved_tracks = extras.saved_tracks.into_iter().map(|track| {
                            profile_import::ImportedTrack {
                                source_id: Some(track.id),
                                title: track.title,
                                artist: track.artist,
                                album: track.album,
                            }
                        }).collect();
                        imported.followed_artists = extras.followed_artists.into_iter().map(|artist| {
                            profile_import::ImportedArtist {
                                source_id: Some(artist.id),
                                name: artist.name,
                            }
                        }).collect();
                        imported.listening_history = extras.listening_history.into_iter().map(|listen| {
                            profile_import::ImportedListen {
                                track: profile_import::ImportedTrack {
                                    source_id: Some(listen.track.id),
                                    title: listen.track.title,
                                    artist: listen.track.artist,
                                    album: listen.track.album,
                                },
                                played_at: listen.played_at,
                                ms_played: None,
                                play_count: 1,
                            }
                        }).collect();
                    }
                    let saved_track_count = imported.saved_tracks.len();
                    let followed_artist_count = imported.followed_artists.len();
                    let listening_event_count = imported.listening_history.len();
                    let mut imported_track_count = 0usize;
                    let mut skipped_playlists = 0usize;
                    let mut track_budget = 50_000usize;
                    for playlist in provider_playlists {
                        let mut imported_tracks = Vec::new();
                        if track_budget > 0 {
                            match provider_auth::fetch_provider_playlist_tracks(
                                provider, &tokens.access_token, &playlist.id
                            ) {
                                Ok(tracks) => {
                                    let keep = tracks.len().min(track_budget);
                                    imported_track_count += keep;
                                    track_budget -= keep;
                                    imported_tracks = tracks.into_iter().take(keep).map(|track| {
                                        profile_import::ImportedTrack {
                                            source_id: Some(track.id),
                                            title: track.title,
                                            artist: track.artist,
                                            album: track.album,
                                        }
                                    }).collect();
                                }
                                Err(_) => skipped_playlists += 1,
                            }
                        }
                        imported.playlists.push(profile_import::ImportedPlaylist {
                            source_id: Some(playlist.id),
                            name: playlist.name,
                            description: playlist.description,
                            artwork_url: playlist.image_url,
                            tracks: imported_tracks,
                        });
                    }
                    let playlist_count = imported.playlists.len();
                    let payload = serde_json::to_string(&imported)
                        .map_err(|_| "Could not prepare the imported provider profile".to_string())?;
                    let imported_id = db.lock().map_err(|_| "The local profile database is unavailable".to_string())?
                        .save_imported_profile(
                            provider_key,
                            imported.display_name.as_deref(),
                            imported.username.as_deref(),
                            &payload,
                        )
                        .map_err(|error| format!("Could not save the imported profile: {error}"))?;
                    if let Some(avatar_url) = imported.avatar_url.as_deref() {
                        let _ = cache_profile_avatar(avatar_url, imported_id);
                    }
                    let ui_for_refresh = ui.clone();
                    let db_for_refresh = Arc::clone(&db);
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_for_refresh.upgrade() {
                            refresh_imported_profile_list(&ui, &db_for_refresh);
                        }
                    });
                    let provider_name = if provider == provider_auth::OAuthProvider::YoutubeData {
                        "YouTube account"
                    } else {
                        "Spotify"
                    };
                    let optional_warning_summary = if provider_warnings.is_empty() {
                        String::new()
                    } else {
                        format!(" Optional data: {}.", provider_warnings.join(" · "))
                    };
                    Ok(format!(
                        "Imported {provider_name} profile {} · {playlist_count} playlists · {imported_track_count} playlist entries · {saved_track_count} saved tracks · {followed_artist_count} followed artists · {listening_event_count} listening events. {} playlist(s) could not be fully read. This imports metadata only; it does not grant streaming access.{}",
                        provider_profile.display_name, skipped_playlists, optional_warning_summary
                    ))
                }
            }
        })();
        let status = result.unwrap_or_else(|error| format!("Provider connection failed: {error}"));
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = ui.upgrade() {
                ui.set_provider_connection_status(status.into());
            }
        });
    });
}

fn disconnect_provider(provider: &'static str, ui: slint::Weak<MainWindow>) {
    std::thread::spawn(move || {
        let status = match token_store::remove_tokens(provider) {
            Ok(()) => format!("Disconnected {} and removed its saved credentials.", provider),
            Err(error) => format!("Could not disconnect {}: {}", provider, error),
        };
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = ui.upgrade() {
                ui.set_provider_connection_status(status.into());
            }
        });
    });
}

#[derive(Clone, Debug)]
struct AudiusArtist { id: String, name: String, handle: String, provider: String, external_url: Option<String> }

#[derive(Clone, Debug)]
struct AudiusCollection {
    id: String,
    title: String,
    creator: String,
    kind: String,
    provider: String,
    external_url: Option<String>,
}

#[derive(Clone, Debug)]
struct AudiusArtistProfile {
    name: String,
    handle: String,
    bio: String,
    follower_count: u64,
    track_count: u64,
    albums: Vec<AudiusCollection>,
    tracks: Vec<Track>,
}

use raptor_audio::player::AudioPlayer;
use raptor_audio::decoder::AudioDecoder;
use raptor_library::{LibraryDatabase, QueueEntry};
use raptor_core::models::{Track, PlaybackSource, PlayerState, PlayerEvent};
use std::sync::{Arc, Mutex};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};
use uuid::Uuid;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let db_path = music_data_dir()?.join("raptor_music.db");
    let db = Arc::new(Mutex::new(LibraryDatabase::new(&db_path)?));
    let player = Arc::new(AudioPlayer::new());

    let ui = MainWindow::new()?;
    restore_provider_connections(ui.as_weak());
    {
        let db_lock = db.lock().unwrap();
        ui.set_discord_presence_enabled(db_lock.get_state_value("discord_presence_enabled").ok().flatten().as_deref() == Some("true"));
        ui.set_discord_client_id(db_lock.get_state_value("discord_client_id").ok().flatten().unwrap_or_default().into());
        ui.set_discord_details_template(db_lock.get_state_value("discord_details_template").ok().flatten().unwrap_or_else(|| "{title}".into()).into());
        ui.set_discord_state_template(db_lock.get_state_value("discord_state_template").ok().flatten().unwrap_or_else(|| "by {artist}".into()).into());
        ui.set_discord_custom_phrase(db_lock.get_state_value("discord_custom_phrase").ok().flatten().unwrap_or_else(|| "Jamming out to".into()).into());
    }
    let discord_connection: Arc<Mutex<Option<DiscordConnection>>> = Arc::new(Mutex::new(None));
    let visible_track_ids = Arc::new(Mutex::new(
        db.lock().unwrap().get_all_tracks().unwrap_or_default()
            .into_iter().filter(is_local_track).map(|track| track.id).collect::<Vec<_>>()
    ));
    let selected_track_id: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    refresh_track_list(&ui, &db);
    refresh_queue_list(&ui, &db);
    refresh_playlist_list(&ui, &db);
    refresh_imported_profile_list(&ui, &db);

    let manual_stopped = Arc::new(AtomicBool::new(false));
    let active_session_token: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    let active_playing_queue_entry_id: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    let last_seek_at: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));
    let online_tracks: Arc<Mutex<Vec<Track>>> = Arc::new(Mutex::new(Vec::new()));
    let online_artists: Arc<Mutex<Vec<AudiusArtist>>> = Arc::new(Mutex::new(Vec::new()));
    let online_collections: Arc<Mutex<Vec<AudiusCollection>>> = Arc::new(Mutex::new(Vec::new()));
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

    let db_for_discord_settings = Arc::clone(&db);
    let connection_for_discord_settings = Arc::clone(&discord_connection);
    let ui_handle_discord_settings = ui.as_weak();
    ui.on_save_discord_presence_clicked(move || {
        let ui = match ui_handle_discord_settings.upgrade() { Some(ui) => ui, None => return };
        let enabled = ui.get_discord_presence_enabled();
        let client_id = ui.get_discord_client_id().to_string().trim().to_string();
        let details = ui.get_discord_details_template().to_string();
        let state = ui.get_discord_state_template().to_string();
        let custom_phrase = ui.get_discord_custom_phrase().to_string();
        {
            let db_lock = db_for_discord_settings.lock().unwrap();
            let _ = db_lock.set_state_value("discord_presence_enabled", if enabled { "true" } else { "false" });
            let _ = db_lock.set_state_value("discord_client_id", &client_id);
            let _ = db_lock.set_state_value("discord_details_template", &details);
            let _ = db_lock.set_state_value("discord_state_template", &state);
            let _ = db_lock.set_state_value("discord_custom_phrase", &custom_phrase);
        }
        if !enabled {
            clear_discord_presence(&mut connection_for_discord_settings.lock().unwrap());
            ui.set_discord_presence_status("Rich Presence is off.".into());
        } else if client_id.is_empty() {
            ui.set_discord_presence_status("Add your Discord application's Client ID, then save.".into());
        } else {
            let title = ui.get_current_track_title().to_string();
            let artist = ui.get_current_track_artist().to_string();
            let result = send_discord_presence(
                &mut connection_for_discord_settings.lock().unwrap(),
                &client_id, &details, &state, &custom_phrase, &title, &artist, "Playing",
            );
            ui.set_discord_presence_status(match result {
                Ok(()) => "Connected to a compatible Discord client.".into(),
                Err(error) => format!("Rich Presence is waiting: {error}").into(),
            });
        }
    });

    let ui_handle_provider_connect = ui.as_weak();
    ui.on_connect_spotify_clicked({
        let ui_weak = ui_handle_provider_connect.clone();
        let db_for_connect = Arc::clone(&db);
        move || start_provider_connection(provider_auth::OAuthProvider::Spotify, ui_weak.clone(), Arc::clone(&db_for_connect))
    });
    ui.on_connect_apple_music_clicked({
        let ui_weak = ui_handle_provider_connect.clone();
        let db_for_connect = Arc::clone(&db);
        move || start_apple_music_connection(ui_weak.clone(), Arc::clone(&db_for_connect))
    });
    ui.on_refresh_apple_music_clicked({
        let ui_weak = ui_handle_provider_connect.clone();
        let db_for_refresh = Arc::clone(&db);
        move || start_apple_music_library_refresh(ui_weak.clone(), Arc::clone(&db_for_refresh))
    });
    ui.on_open_external_service_clicked(move |service| {
        let url = match service.as_str() {
            "spotify" => "https://open.spotify.com/",
            "tidal" => "https://tidal.com/",
            "apple_music" => "https://music.apple.com/",
            "youtube_music" => "https://music.youtube.com/",
            "jamendo" => "https://www.jamendo.com/",
            "audius" => "https://audius.co/",
            _ => {
                eprintln!("Raptor Music: rejected unknown external music service");
                return;
            }
        };
        if let Err(error) = std::process::Command::new("gio").arg("open").arg(url).spawn() {
            eprintln!("Raptor Music could not open external music service: {error}");
        }
    });
    ui.on_connect_youtube_clicked({
        let ui_weak = ui_handle_provider_connect.clone();
        let db_for_connect = Arc::clone(&db);
        move || start_provider_connection(provider_auth::OAuthProvider::YoutubeData, ui_weak.clone(), Arc::clone(&db_for_connect))
    });
    ui.on_disconnect_spotify_clicked({
        let ui_weak = ui_handle_provider_connect.clone();
        move || disconnect_provider("spotify", ui_weak.clone())
    });
    ui.on_disconnect_apple_music_clicked({
        let ui_weak = ui_handle_provider_connect.clone();
        move || disconnect_provider("apple-music-user", ui_weak.clone())
    });
    ui.on_disconnect_tidal_clicked({
        let ui_weak = ui_handle_provider_connect.clone();
        move || disconnect_provider("tidal", ui_weak.clone())
    });
    ui.on_disconnect_youtube_clicked({
        let ui_weak = ui_handle_provider_connect.clone();
        move || disconnect_provider("youtube", ui_weak.clone())
    });

    let pending_import: Arc<Mutex<Option<profile_import::ImportedProfile>>> = Arc::new(Mutex::new(None));
    let ui_handle_profile_import = ui.as_weak();
    let pending_for_preview = Arc::clone(&pending_import);
    ui.on_import_profile_clicked(move || {
        let selected_files = rfd::FileDialog::new()
            .add_filter("Profile export files", &["json"])
            .pick_files();
        let files = match selected_files {
            Some(files) if !files.is_empty() => files,
            _ => return,
        };
        let ui_weak = ui_handle_profile_import.clone();
        let pending_for_thread = Arc::clone(&pending_for_preview);
        std::thread::spawn(move || {
            let mut combined = profile_import::ImportedProfile::default();
            let mut imported_files = 0usize;
            let mut errors = Vec::new();
            for path in files {
                match std::fs::read_to_string(&path) {
                    Ok(payload) => match profile_import::parse_profile_export(&payload) {
                        Ok(part) => {
                            combined.merge(part);
                            imported_files += 1;
                        }
                        Err(error) => errors.push(format!("{}: {}", path.file_name().unwrap_or_default().to_string_lossy(), error)),
                    },
                    Err(error) => errors.push(format!("{}: {}", path.file_name().unwrap_or_default().to_string_lossy(), error)),
                }
            }
            let summary = combined.summary();
            if imported_files > 0 {
                *pending_for_thread.lock().unwrap() = Some(combined.clone());
            } else {
                *pending_for_thread.lock().unwrap() = None;
            }
            let status = if imported_files == 0 {
                format!("No supported profile data imported. {}", errors.join(" · "))
            } else {
                let identity = combined.display_name.as_deref()
                    .or(combined.username.as_deref()).unwrap_or("Profile");
                let mut message = format!(
                    "{} · {} file(s) · {} playlist(s) / {} playlist tracks · {} saved tracks · {} followed artists · {} library artists · {} listening events · avatar {}. Preview only; nothing has been added to your library yet.",
                    identity, imported_files, summary.playlists, summary.playlist_tracks,
                    summary.saved_tracks, summary.followed_artists, summary.library_artists, summary.listening_events,
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

    let db_for_profile_browse = Arc::clone(&db);
    let ui_handle_profile_browse = ui.as_weak();
    ui.on_refresh_imported_profiles_clicked(move || {
        if let Some(ui) = ui_handle_profile_browse.upgrade() {
            refresh_imported_profile_list(&ui, &db_for_profile_browse);
        }
    });

    let db_for_profile_select = Arc::clone(&db);
    let ui_handle_profile_select = ui.as_weak();
    ui.on_imported_profile_selected(move |index| {
        let ui = match ui_handle_profile_select.upgrade() { Some(ui) => ui, None => return };
        let db_lock = db_for_profile_select.lock().unwrap();
        let profiles = db_lock.get_imported_profiles().unwrap_or_default();
        let record = match profiles.get(index as usize) {
            Some(record) => record,
            None => { ui.set_imported_profile_detail("No imported profile selected.".into()); return; }
        };
        let detail = match db_lock.get_imported_profile_payload(record.id) {
            Ok(Some(payload)) => match serde_json::from_str::<profile_import::ImportedProfile>(&payload) {
                Ok(profile) => {
                    let summary = profile.summary();
                    let playlists = profile.playlists.iter().take(12).map(|p| format!("• {} ({} tracks)", p.name, p.tracks.len())).collect::<Vec<_>>().join("\\n");
                    let saved = profile.saved_tracks.iter().take(8).map(|t| format!("• {} — {}", t.title, t.artist)).collect::<Vec<_>>().join("\\n");
                    let artists = profile.followed_artists.iter().take(8).map(|a| a.name.clone()).collect::<Vec<_>>().join(", ");
                    let library_artists = profile.library_artists.iter().take(8).map(|a| a.name.clone()).collect::<Vec<_>>().join(", ");
                    let history = profile.listening_history.iter().take(5).map(|h| format!("• {} — {}", h.track.title, h.track.artist)).collect::<Vec<_>>().join("\\n");
                    format!("{} · {}\\n{} playlists · {} saved tracks · {} followed artists · {} library artists · {} listening events\\n\\nPLAYLISTS\\n{}\\n\\nSAVED TRACKS\\n{}\\n\\nFOLLOWED ARTISTS\\n{}\\n\\nLIBRARY ARTISTS\\n{}\\n\\nRECENT LISTENING HISTORY\\n{}\\n\\nImported {}", record.display_name.as_deref().or(record.username.as_deref()).unwrap_or("Imported profile"), record.provider, summary.playlists, summary.saved_tracks, summary.followed_artists, summary.library_artists, summary.listening_events, if playlists.is_empty() { "No playlists in this export" } else { &playlists }, if saved.is_empty() { "No saved tracks in this export" } else { &saved }, if artists.is_empty() { "No followed artists in this export" } else { &artists }, if library_artists.is_empty() { "No library artists in this export" } else { &library_artists }, if history.is_empty() { "No listening history in this export" } else { &history }, record.imported_at)
                }
                Err(error) => format!("This saved profile could not be read: {error}")
            },
            Ok(None) => "The saved profile payload is missing.".to_string(),
            Err(error) => format!("Could not load profile: {error}"),
        };
        ui.set_imported_profile_detail(detail.into());
    });

    // Persist only after the user explicitly confirms the preview.
    let pending_for_confirm = Arc::clone(&pending_import);
    let db_for_profile_confirm = Arc::clone(&db);
    let ui_handle_profile_confirm = ui.as_weak();
    ui.on_confirm_profile_import_clicked(move || {
        let profile = match pending_for_confirm.lock().unwrap().take() {
            Some(profile) => profile,
            None => {
                if let Some(ui) = ui_handle_profile_confirm.upgrade() {
                    ui.set_profile_import_status("Choose and preview an export before confirming the import.".into());
                }
                return;
            }
        };
        let provider = if profile.source.trim().is_empty() { "Imported profile" } else { profile.source.as_str() };
        let display_name = profile.display_name.as_deref();
        let username = profile.username.as_deref();
        let payload = match serde_json::to_string(&profile) {
            Ok(payload) => payload,
            Err(error) => {
                if let Some(ui) = ui_handle_profile_confirm.upgrade() {
                    ui.set_profile_import_status(format!("Could not prepare profile data: {error}").into());
                }
                return;
            }
        };
        let result = db_for_profile_confirm.lock().unwrap()
            .save_imported_profile(provider, display_name, username, &payload);
        match result {
            Ok(id) => {
                if let Some(ui) = ui_handle_profile_confirm.upgrade() {
                    ui.set_profile_import_status(format!(
                        "Profile imported and saved separately from your local library. Import ID: {id}"
                    ).into());
                }
                let avatar_url = profile.avatar_url.clone();
                let ui_weak = ui_handle_profile_confirm.clone();
                let db_for_avatar = Arc::clone(&db_for_profile_confirm);
                std::thread::spawn(move || {
                    if let Some(url) = avatar_url.as_deref() {
                        let _ = cache_profile_avatar(url, id);
                    }
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            refresh_imported_profile_list(&ui, &db_for_avatar);
                        }
                    });
                });
            }
            Err(error) => {
                if let Some(ui) = ui_handle_profile_confirm.upgrade() {
                    ui.set_profile_import_status(format!("Profile import failed: {error}").into());
                }
            }
        }
    });

    let db_for_search = Arc::clone(&db);
    let visible_ids_for_search = Arc::clone(&visible_track_ids);
    let selected_id_for_search = Arc::clone(&selected_track_id);
    let online_tracks_for_search = Arc::clone(&online_tracks);
    let online_artists_for_search = Arc::clone(&online_artists);
    let online_collections_for_search = Arc::clone(&online_collections);
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
            ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_search_status("Online discovery is available in the Discover tab".into());
            return;
        }

        if query.trim().is_empty() {
            *online_tracks_for_search.lock().unwrap() = Vec::new();
            *online_artists_for_search.lock().unwrap() = Vec::new();
            ui.set_online_artist_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_search_status("Search artist names, song titles or keywords".into());
            return;
        }

        ui.set_online_search_status("Searching…".into());
        let query_for_thread = query.trim().to_string();
        let sort_method = ui.get_online_sort_method().to_string();
        let ui_weak = ui_handle_search.clone();
        let online_tracks = Arc::clone(&online_tracks_for_search);
        let online_artists = Arc::clone(&online_artists_for_search);
        let online_collections = Arc::clone(&online_collections_for_search);
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
            let apple_artist_query = query_for_thread.clone();
            let apple_artist_worker = std::thread::spawn(move || search_apple_music_artists(&apple_artist_query));
            let mb_artist_query = query_for_thread.clone();
            let mb_artist_worker = std::thread::spawn(move || search_musicbrainz_artists(&mb_artist_query));
            let apple_query = query_for_thread.clone();
            let apple_worker = std::thread::spawn(move || search_apple_music_tracks(&apple_query));
            let jamendo_query = query_for_thread.clone();
            let jamendo_worker = std::thread::spawn(move || search_jamendo_tracks(&jamendo_query));
            let audius_result = if sort_method == "independent" {
                // Blend relevance-ranked and recent uploads instead of letting
                // play counts dominate discovery. Alternate sources and dedupe
                // by stable provider-backed track ID.
                let recent_query = query_for_thread.clone();
                let recent_worker = std::thread::spawn(move || search_audius_tracks(&recent_query, "recent"));
                let relevant = search_audius_tracks(&query_for_thread, "relevant");
                let recent = recent_worker.join()
                    .unwrap_or_else(|_| Err("Recent discovery worker stopped unexpectedly".to_string()));
                match (relevant, recent) {
                    (Ok(relevant), Ok(recent)) => Ok(merge_independent_discovery(relevant, recent)),
                    (Ok(relevant), Err(_)) => Ok(relevant),
                    (Err(_), Ok(recent)) => Ok(recent),
                    (Err(error), Err(_)) => Err(error),
                }
            } else {
                search_audius_tracks(&query_for_thread, &sort_method)
            };
            let collection_query = query_for_thread.clone();
            let apple_collection_query = query_for_thread.clone();
            let apple_collection_worker = std::thread::spawn(move || search_apple_music_collections(&apple_collection_query));
            let mb_collection_query = query_for_thread.clone();
            let mb_collection_worker = std::thread::spawn(move || search_musicbrainz_collections(&mb_collection_query));
            let collection_worker = std::thread::spawn(move || search_audius_collections(&collection_query));
            let artist_result = artist_worker.join()
                .unwrap_or_else(|_| Err("Artist search worker stopped unexpectedly".to_string()));
            let apple_artist_result = apple_artist_worker.join()
                .unwrap_or_else(|_| Err("Apple Music artist search worker stopped unexpectedly".to_string()));
            let mb_artist_result = mb_artist_worker.join()
                .unwrap_or_else(|_| Err("MusicBrainz artist search worker stopped unexpectedly".to_string()));
            let apple_result = apple_worker.join()
                .unwrap_or_else(|_| Err("Apple Music search worker stopped unexpectedly".to_string()));
            let jamendo_result = jamendo_worker.join()
                .unwrap_or_else(|_| Err("Jamendo search worker stopped unexpectedly".to_string()));
            if generation.load(Ordering::Acquire) != request_generation {
                return;
            }

            let mut tracks = audius_result.unwrap_or_default();
            let audius_count = tracks.len();
            let apple_error = apple_result.is_err();
            let apple_tracks = apple_result.unwrap_or_default();
            let apple_count = apple_tracks.len();
            tracks.extend(apple_tracks);
            let jamendo_error = jamendo_result.is_err();
            let jamendo_tracks = jamendo_result.unwrap_or_default();
            let jamendo_count = jamendo_tracks.len();
            tracks.extend(jamendo_tracks);
            let count = tracks.len();
            *online_tracks.lock().unwrap() = tracks.clone();
            let rows = tracks_to_slint(&tracks);
            let collection_result = collection_worker.join()
                .unwrap_or_else(|_| Err("Collection search worker stopped unexpectedly".to_string()));
            let mut collections = collection_result.unwrap_or_default();
            let audius_collection_count = collections.len();
            let apple_collection_result = apple_collection_worker.join()
                .unwrap_or_else(|_| Err("Apple Music collection search worker stopped unexpectedly".to_string()));
            let apple_collection_error = apple_collection_result.is_err();
            let apple_collections = apple_collection_result.unwrap_or_default();
            let apple_collection_count = apple_collections.len();
            collections.extend(apple_collections);
            let mb_collection_result = mb_collection_worker.join().unwrap_or_else(|_| Err("MusicBrainz release search worker stopped unexpectedly".to_string()));
            let mb_collection_error = mb_collection_result.is_err();
            let mb_collections = mb_collection_result.unwrap_or_default();
            let mb_collection_count = mb_collections.len();
            collections.extend(mb_collections);
            *online_collections.lock().unwrap() = collections.clone();
            let collection_count = collections.len();
            let collection_rows = collections.iter().map(|item| TrackData {
                id: item.id.clone().into(),
                title: item.title.clone().into(),
                artist: format!("{} · {} · {}", if item.provider == "apple_music" { "Apple Music" } else { "Audius" }, item.creator, item.kind).into(),
                album: item.kind.clone().into(),
                duration: "Open".into(),
            }).collect::<Vec<_>>();
            let apple_artist_error = apple_artist_result.is_err();
            let artist_error = artist_result.is_err() || apple_artist_error;
            let mut artists = artist_result.unwrap_or_default();
            let apple_artists = apple_artist_result.unwrap_or_default();
            let apple_artist_count = apple_artists.len();
            artists.extend(apple_artists);
            let mb_artist_error = mb_artist_result.is_err();
            let mb_artists = mb_artist_result.unwrap_or_default();
            let mb_artist_count = mb_artists.len();
            artists.extend(mb_artists);
            *online_artists.lock().unwrap() = artists.clone();
            let artist_count = artists.len();
            let artist_rows = artists.iter().map(|artist| TrackData {
                id: artist.id.clone().into(), title: artist.name.clone().into(),
                artist: match artist.provider.as_str() { "apple_music" => "Apple Music artist".into(), "musicbrainz" => "MusicBrainz artist".into(), _ => format!("@{}", artist.handle).into() },
                album: match artist.provider.as_str() { "apple_music" => "Apple Music".into(), "musicbrainz" => "Discography metadata".into(), _ => "Audius artist profile".into() },
                duration: "Open".into(),
            }).collect::<Vec<_>>();
            let mut status = format!("{count} tracks · {artist_count} artists · {audius_collection_count} Audius collections · {apple_collection_count} Apple Music albums/playlists · {mb_collection_count} MusicBrainz releases");
            if mb_artist_count > 0 { status.push_str(&format!(" · {mb_artist_count} MusicBrainz artists")); }
            if mb_collection_error { status.push_str(" · MusicBrainz release search unavailable"); }
            if mb_artist_error { status.push_str(" · MusicBrainz artist search unavailable"); }
            if apple_collection_error && std::env::var("RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN").is_ok() {
                status.push_str(" · Apple Music collections unavailable");
            }
            if apple_count > 0 {
                status.push_str(&format!(" · {apple_count} Apple Music previews"));
            }
            if apple_artist_count > 0 {
                status.push_str(&format!(" · {apple_artist_count} Apple Music artists"));
            }
            if apple_count == 0 && apple_artist_count == 0 && std::env::var("RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN").is_err() {
                status.push_str(" · Apple Music catalog not configured");
            } else if apple_error || apple_artist_error {
                status.push_str(" · Apple Music search unavailable");
            }
            if jamendo_count > 0 {
                status.push_str(&format!(" · {jamendo_count} Jamendo links"));
            } else if jamendo_error && std::env::var("RAPTOR_JAMENDO_CLIENT_ID").is_err() {
                status.push_str(" · Jamendo not configured");
            } else if jamendo_error {
                status.push_str(" · Jamendo search unavailable");
            }
            if audius_count == 0 && apple_count == 0 && jamendo_count == 0 && artist_count == 0
                && collection_count == 0 && apple_collection_count == 0 && mb_collection_count == 0 && mb_artist_count == 0 {
                status = "No matching tracks, artists, albums or playlists found".to_string();
            }
            if artist_error {
                status.push_str(" · Some artist results are unavailable");
            }
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(ui) = ui_weak.upgrade() {
                    ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(rows)));
                    ui.set_online_artist_list(slint::ModelRc::new(slint::VecModel::from(artist_rows)));
                    ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(collection_rows)));
                    ui.set_online_search_status(status.into());
                }
            });
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

    let collections_for_select = Arc::clone(&online_collections);
    let tracks_for_collection = Arc::clone(&online_tracks);
    let generation_for_collection = Arc::clone(&online_search_generation);
    let ui_handle_collection = ui.as_weak();
    ui.on_collection_selected(move |idx| {
        let collection = collections_for_select.lock().unwrap().get(idx as usize).cloned();
        let Some(collection) = collection else { return; };
        if collection.provider == "musicbrainz" {
            let result = collection.external_url.as_deref()
                .ok_or_else(|| "MusicBrainz release has no verified destination".to_string())
                .and_then(open_musicbrainz_link);
            if let Some(ui) = ui_handle_collection.upgrade() {
                ui.set_online_search_status(match result { Ok(()) => format!("Opened {} release details on MusicBrainz", collection.title).into(), Err(error) => error.into() });
            }
            return;
        }
        if collection.provider == "apple_music" {
            let result = collection.external_url.as_deref()
                .ok_or_else(|| "Apple Music collection has no verified destination".to_string())
                .and_then(open_apple_music_link);
            if let Some(ui) = ui_handle_collection.upgrade() {
                ui.set_online_search_status(match result {
                    Ok(()) => format!("Opened {} on Apple Music", collection.title).into(),
                    Err(error) => error.into(),
                });
            }
            return;
        }
        let request_generation = generation_for_collection.fetch_add(1, Ordering::AcqRel) + 1;
        if let Some(ui) = ui_handle_collection.upgrade() {
            ui.set_online_search_status(format!("Loading {}…", collection.title).into());
        }
        let ui_weak = ui_handle_collection.clone();
        let tracks_state = Arc::clone(&tracks_for_collection);
        let generation_state = Arc::clone(&generation_for_collection);
        std::thread::spawn(move || {
            let result = fetch_audius_collection_tracks(&collection);
            let tracks = match result {
                Ok(tracks) => tracks,
                Err(error) => {
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_online_search_status(error.into());
                        }
                    });
                    return;
                }
            };
            *tracks_state.lock().unwrap() = tracks.clone();
            let rows = tracks_to_slint(&tracks);
            let title = collection.title.clone();
            let count = tracks.len();
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(ui) = ui_weak.upgrade() {
                    if generation_state.load(Ordering::Acquire) == request_generation {
                        ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(rows)));
                        ui.set_selected_online_track_index(-1);
                        ui.set_online_search_status(format!("{title} · {count} tracks").into());
                    }
                }
            });
        });
    });

    let artists_for_profile = Arc::clone(&online_artists);
    let tracks_for_profile = Arc::clone(&online_tracks);
    let collections_for_profile = Arc::clone(&online_collections);
    let generation_for_profile = Arc::clone(&online_search_generation);
    let ui_handle_profile = ui.as_weak();
    ui.on_artist_selected(move |idx| {
        let artist = artists_for_profile.lock().unwrap().get(idx as usize).cloned();
        let artist = match artist {
            Some(artist) => artist,
            None => return,
        };
        if artist.provider == "musicbrainz" {
            let request_generation = generation_for_profile.fetch_add(1, Ordering::AcqRel) + 1;
            if let Some(ui) = ui_handle_profile.upgrade() {
                ui.set_active_view("artist".into());
                ui.set_artist_profile_name(artist.name.clone().into());
                ui.set_artist_profile_handle("MusicBrainz · Discography".into());
                ui.set_artist_profile_bio("Loading indexed releases…".into());
                ui.set_artist_profile_stats("Loading discography…".into());
                ui.set_artist_profile_status("Fetching albums, EPs and singles…".into());
                ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
                ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
                ui.set_selected_online_track_index(-1);
            }
            let ui_weak = ui_handle_profile.clone();
            let generation = Arc::clone(&generation_for_profile);
            let collections_state = Arc::clone(&collections_for_profile);
            std::thread::spawn(move || {
                let result = musicbrainz_artist_discography(&artist);
                if generation.load(Ordering::Acquire) != request_generation { return; }
                let (releases, bio, stats, status) = match result {
                    Ok(releases) => {
                        let count = releases.len();
                        let bio = if count == 0 {
                            "No release groups are indexed for this artist yet.".to_string()
                        } else {
                            "Discography metadata from MusicBrainz. Select a release below to open its official credits and track listing. These entries do not contain playable audio.".to_string()
                        };
                        (releases, bio, format!("{count} indexed release groups"), if count == 0 {
                            "No indexed albums, EPs or singles found".to_string()
                        } else { format!("{count} releases loaded · metadata only") })
                    }
                    Err(error) => (Vec::new(), "Discography information is temporarily unavailable.".to_string(), String::new(), error),
                };
                let rows = releases.iter().map(|release| TrackData {
                    id: release.id.clone().into(),
                    title: release.title.clone().into(),
                    artist: release.creator.clone().into(),
                    album: release.kind.clone().into(),
                    duration: "Open".into(),
                }).collect::<Vec<_>>();
                *collections_state.lock().unwrap() = releases;
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(ui) = ui_weak.upgrade() {
                        ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(rows)));
                        ui.set_artist_profile_bio(bio.into());
                        ui.set_artist_profile_stats(stats.into());
                        ui.set_artist_profile_status(status.into());
                    }
                });
            });
            return;
        }
        if artist.provider == "apple_music" {
            let request_generation = generation_for_profile.fetch_add(1, Ordering::AcqRel) + 1;
            if let Some(ui) = ui_handle_profile.upgrade() {
                ui.set_active_view("artist".into());
                ui.set_artist_profile_name(artist.name.clone().into());
                ui.set_artist_profile_handle("Apple Music · Catalog discography".into());
                ui.set_artist_profile_bio("Loading catalog albums…".into());
                ui.set_artist_profile_stats("Loading discography…".into());
                ui.set_artist_profile_status("Fetching artist albums…".into());
                ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
                ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
                ui.set_selected_online_track_index(-1);
            }
            let ui_weak = ui_handle_profile.clone();
            let generation = Arc::clone(&generation_for_profile);
            let collections_state = Arc::clone(&collections_for_profile);
            std::thread::spawn(move || {
                let result = apple_music_artist_discography(&artist);
                if generation.load(Ordering::Acquire) != request_generation { return; }
                let (albums, bio, stats, status) = match result {
                    Ok(albums) => {
                        let count = albums.len();
                        let bio = if count == 0 {
                            "No catalog albums are available for this artist in the selected storefront.".to_string()
                        } else {
                            "Apple Music catalog discography. Select an album below to open its official Apple Music page; full subscription playback is not provided by this catalog view.".to_string()
                        };
                        (albums, bio, format!("{count} catalog albums"), if count == 0 {
                            "No albums returned by the Apple Music catalog".to_string()
                        } else { format!("{count} albums loaded · catalog metadata") })
                    }
                    Err(error) => (Vec::new(), "Apple Music discography information is temporarily unavailable.".to_string(), String::new(), error),
                };
                let rows = albums.iter().map(|album| TrackData {
                    id: album.id.clone().into(),
                    title: album.title.clone().into(),
                    artist: album.creator.clone().into(),
                    album: album.kind.clone().into(),
                    duration: "Open".into(),
                }).collect::<Vec<_>>();
                *collections_state.lock().unwrap() = albums;
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(ui) = ui_weak.upgrade() {
                        ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(rows)));
                        ui.set_artist_profile_bio(bio.into());
                        ui.set_artist_profile_stats(stats.into());
                        ui.set_artist_profile_status(status.into());
                    }
                });
            });
            return;
        }
        let request_generation = generation_for_profile.fetch_add(1, Ordering::AcqRel) + 1;
            if let Some(ui) = ui_handle_profile.upgrade() {
                ui.set_active_view("artist".into());
                ui.set_artist_profile_name(artist.name.clone().into());
                ui.set_artist_profile_handle("Apple Music · Catalog discography".into());
                ui.set_artist_profile_bio("Loading catalog albums…".into());
                ui.set_artist_profile_stats("Loading discography…".into());
                ui.set_artist_profile_status("Fetching artist albums…".into());
                ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
                ui.set_selected_online_track_index(-1);
            }
            let ui_weak = ui_handle_profile.clone();
            let generation = Arc::clone(&generation_for_profile);
            std::thread::spawn(move || {
                let result = apple_music_artist_discography(&artist);
                if generation.load(Ordering::Acquire) != request_generation { return; }
                let (bio, stats, status) = match result {
                    Ok(albums) => {
                        let count = albums.len();
                        let lines = albums.iter().map(|album| format!("{} · {}",
                            album.title, album.kind)).collect::<Vec<_>>();
                        let summary = if lines.is_empty() { "No catalog albums are available for this artist in the selected storefront.".to_string() }
                            else { lines.join("\\n") };
                        (summary, format!("{count} catalog albums"), if count == 0 {
                            "No albums returned by the Apple Music catalog".to_string()
                        } else { "Catalog metadata loaded · open the artist on Apple Music for full credits and track listings".to_string() })
                    }
                    Err(error) => ("Apple Music discography information is temporarily unavailable.".to_string(), String::new(), error),
                };
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(ui) = ui_weak.upgrade() {
                        ui.set_artist_profile_bio(bio.into());
                        ui.set_artist_profile_stats(stats.into());
                        ui.set_artist_profile_status(status.into());
                    }
                });
            });
            return;
        }
        let request_generation = generation_for_profile.fetch_add(1, Ordering::AcqRel) + 1;
        if let Some(ui) = ui_handle_profile.upgrade() {
            ui.set_active_view("artist".into());
            ui.set_artist_profile_name(artist.name.clone().into());
            ui.set_artist_profile_handle(format!("@{}", artist.handle).into());
            ui.set_artist_profile_bio("Loading artist information…".into());
            ui.set_artist_profile_stats("Loading profile…".into());
            ui.set_artist_profile_status("Loading tracks…".into());
            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(Vec::<TrackData>::new())));
            ui.set_selected_online_track_index(-1);
        }
        let ui_weak = ui_handle_profile.clone();
        let artists_tracks = Arc::clone(&tracks_for_profile);
        let collections_state = Arc::clone(&collections_for_profile);
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
                    let album_count = profile.albums.len();
                    let bio = profile.bio.clone();
                    let album_rows = profile.albums.iter().map(|album| TrackData {
                        id: album.id.clone().into(),
                        title: album.title.clone().into(),
                        artist: album.creator.clone().into(),
                        album: album.kind.clone().into(),
                        duration: "Open".into(),
                    }).collect::<Vec<_>>();
                    let albums_for_state = profile.albums.clone();
                    let stats = format!("{} tracks · {} followers · {} albums", profile.track_count, profile.follower_count, album_count);
                    let status = if rows.is_empty() {
                        format!("No playable tracks available · {album_count} albums listed")
                    } else {
                        format!("{} tracks available · {} albums listed", rows.len(), album_count)
                    };
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_artist_profile_name(profile.name.into());
                            ui.set_artist_profile_handle(format!("@{}", profile.handle).into());
                            ui.set_artist_profile_bio(bio.into());
                            ui.set_artist_profile_stats(stats.into());
                            ui.set_artist_profile_status(status.into());
                            ui.set_online_collection_list(slint::ModelRc::new(slint::VecModel::from(album_rows)));
                            *collections_state.lock().unwrap() = albums_for_state;
                            ui.set_online_track_list(slint::ModelRc::new(slint::VecModel::from(rows)));
                        }
                    });
                }
                Err(_error) => {
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = ui_weak.upgrade() {
                            ui.set_artist_profile_bio("Artist information is temporarily unavailable.".into());
                            ui.set_artist_profile_stats("".into());
                            ui.set_artist_profile_status("Could not load this artist's catalog. Try again.".into());
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

    let db_for_track_menu = Arc::clone(&db);
    let online_for_track_menu = Arc::clone(&online_tracks);
    let visible_for_track_menu = Arc::clone(&visible_track_ids);
    let ui_handle_track_menu = ui.as_weak();
    ui.on_track_menu_action(move |index, source, action, playlist_index| {
        let ui = match ui_handle_track_menu.upgrade() { Some(ui) => ui, None => return };
        let db_lock = db_for_track_menu.lock().unwrap();
        let track = if source == "online" {
            online_for_track_menu.lock().unwrap().get(index as usize).cloned()
        } else {
            let id = visible_for_track_menu.lock().unwrap().get(index as usize).copied();
            id.and_then(|id| db_lock.get_all_tracks().unwrap_or_default().into_iter().find(|track| track.id == id))
        };
        let track = match track { Some(track) => track, None => return };
        if source == "online" && db_lock.upsert_track(&track).is_err() {
            ui.set_player_state_label("Could not save this online track".into());
            return;
        }
        let result = if action == "queue" {
            let mut queue = db_lock.get_queue().unwrap_or_default();
            queue.push(QueueEntry { queue_entry_id: Uuid::new_v4(), track_id: track.id, position: queue.len() as i32 });
            db_lock.save_queue(&queue)
        } else if action == "playlist" {
            let playlists = db_lock.get_playlists().unwrap_or_default();
            match playlists.get(playlist_index as usize) {
                Some(playlist) => db_lock.add_track_to_playlist(playlist.id, track.id),
                None => return,
            }
        } else {
            return;
        };
        drop(db_lock);
        if result.is_ok() {
            if action == "queue" {
                refresh_queue_list(&ui, &db_for_track_menu);
                ui.set_player_state_label(format!("Added {} to the queue", track.title).into());
            } else {
                ui.set_player_state_label(format!("Added {} to playlist", track.title).into());
            }
        } else {
            ui.set_player_state_label("Could not update your music collection".into());
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
        let direct_selection = ui.get_selected_online_track_index() >= 0 || ui.get_selected_track_index() >= 0;
        let selection_changed = ui.get_selected_queue_index() != ui.get_playing_queue_index();
        if !direct_selection {
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
        }
        manual_stopped_for_play.store(false, Ordering::Release);

        let (target_source, target_id, target_queue_entry_id) = {
            let db_lock = db_for_play.lock().unwrap();
            let queue_entries = db_lock.get_queue().unwrap_or_default();
            let all_tracks = db_lock.get_all_tracks().unwrap_or_default();

            if direct_selection {
                let selected_id = *selected_id_for_play.lock().unwrap();
                let track = match all_tracks.iter().find(|track| Some(track.id) == selected_id) {
                    Some(track) => track.clone(),
                    None => { ui.set_player_state_label("Select a track first".into()); return; }
                };
                let mut queue = queue_entries;
                let entry = QueueEntry {
                    queue_entry_id: Uuid::new_v4(),
                    track_id: track.id,
                    position: queue.len() as i32,
                };
                queue.push(entry.clone());
                if db_lock.save_queue(&queue).is_err() {
                    ui.set_player_state_label("Could not update the queue".into());
                    return;
                }
                ui.set_selected_queue_index((queue.len() - 1) as i32);
                (track.source, track.id, entry.queue_entry_id)
            } else if !queue_entries.is_empty() {
                let qidx = ui.get_selected_queue_index();
                let target_qidx = if qidx >= 0 && (qidx as usize) < queue_entries.len() { qidx as usize } else { 0 };
                let entry = &queue_entries[target_qidx];
                let track = all_tracks.iter().find(|t| t.id == entry.track_id).cloned();
                match track {
                    Some(t) => (t.source, t.id, entry.queue_entry_id),
                    None => return,
                }
            } else {
                ui.set_player_state_label("Choose a track to play".into());
                return;
            }
        };

        if let PlaybackSource::RemoteStream { provider_id, provider_track_id } = &target_source {
            if provider_id == "jamendo_external" {
                match open_jamendo_track(provider_track_id) {
                    Ok(()) => ui.set_player_state_label("Opening this track on Jamendo · playback stays on the artist's licensed page".into()),
                    Err(error) => ui.set_player_state_label(error.into()),
                }
                return;
            }
        }

        let session_token = Uuid::new_v4();
        *session_token_for_play.lock().unwrap() = Some(session_token);
        *active_entry_for_play.lock().unwrap() = Some(target_queue_entry_id);

        ui.set_selected_track_index(-1);
        ui.set_selected_online_track_index(-1);
        refresh_queue_list(&ui, &db_for_play);
        ui.set_player_state_label("Loading".into());
        if let Err(e) = player_for_play.play(target_source, target_id, target_queue_entry_id, session_token) {
            eprintln!("Playback error: {}", e);
            ui.set_player_state_label("Error".into());
        }
    });

    let player_for_skip_back = Arc::clone(&player);
    let session_for_skip_back = Arc::clone(&active_session_token);
    let seek_time_for_skip_back = Arc::clone(&last_seek_at);
    ui.on_skip_backward_clicked(move || {
        if let Some(token) = *session_for_skip_back.lock().unwrap() {
            let position = player_for_skip_back.get_position_secs().saturating_sub(15);
            *seek_time_for_skip_back.lock().unwrap() = Some(Instant::now());
            player_for_skip_back.seek(position as f64, token);
        }
    });

    let player_for_skip_forward = Arc::clone(&player);
    let session_for_skip_forward = Arc::clone(&active_session_token);
    let seek_time_for_skip_forward = Arc::clone(&last_seek_at);
    ui.on_skip_forward_clicked(move || {
        if let Some(token) = *session_for_skip_forward.lock().unwrap() {
            let position = player_for_skip_forward.get_position_secs();
            let duration = player_for_skip_forward.get_duration_secs().unwrap_or(position);
            let target = position.saturating_add(15).min(duration);
            *seek_time_for_skip_forward.lock().unwrap() = Some(Instant::now());
            player_for_skip_forward.seek(target as f64, token);
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
    let discord_for_poll = Arc::clone(&discord_connection);

    std::thread::spawn(move || {
        let mut last_persisted_position = u64::MAX;
        let mut current_presence_title = String::new();
        let mut current_presence_artist = String::new();
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
                        current_presence_title = title.clone();
                        current_presence_artist = artist.clone();
                        update_discord_from_database(
                            &db_for_poll, &discord_for_poll,
                            &current_presence_title, &current_presence_artist, "Playing",
                        );

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
                        update_discord_from_database(&db_for_poll, &discord_for_poll, &current_presence_title, &current_presence_artist, "Paused");
                        let ui_weak = ui_handle_poll.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = ui_weak.upgrade() {
                                ui.set_player_state_label("Paused".into());
                            }
                        });
                    }
                    PlayerEvent::Resumed { session_token } => {
                        if Some(session_token) != *session_token_for_poll.lock().unwrap() { continue; }
                        update_discord_from_database(&db_for_poll, &discord_for_poll, &current_presence_title, &current_presence_artist, "Playing");
                        let ui_weak = ui_handle_poll.clone();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(ui) = ui_weak.upgrade() {
                                ui.set_player_state_label("Playing".into());
                            }
                        });
                    }
                    PlayerEvent::Stopped { session_token } | PlayerEvent::SessionTerminated { session_token } => {
                        clear_discord_presence(&mut discord_for_poll.lock().unwrap());
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

fn render_presence_template(template: &str, title: &str, artist: &str) -> String {
    template.replace("{title}", title).replace("{artist}", artist)
}

#[cfg(unix)]
struct DiscordConnection {
    client_id: String,
    stream: UnixStream,
}

#[cfg(not(unix))]
struct DiscordConnection;

#[cfg(unix)]
fn write_discord_frame(stream: &mut UnixStream, opcode: u32, payload: &serde_json::Value) -> Result<(), String> {
    let bytes = serde_json::to_vec(payload).map_err(|error| error.to_string())?;
    let length = u32::try_from(bytes.len()).map_err(|_| "Discord RPC payload is too large".to_string())?;
    stream.write_all(&opcode.to_le_bytes()).map_err(|error| error.to_string())?;
    stream.write_all(&length.to_le_bytes()).map_err(|error| error.to_string())?;
    stream.write_all(&bytes).map_err(|error| error.to_string())
}

#[cfg(unix)]
fn append_discord_socket_candidates(candidates: &mut Vec<PathBuf>, root: &Path) {
    // Native installs expose the socket directly in the runtime directory.
    // Flatpak clients commonly place it inside their application runtime dir.
    const CLIENT_IDS: &[&str] = &[
        "com.discordapp.Discord",
        "com.discordapp.DiscordCanary",
        "com.discordapp.DiscordPTB",
        "dev.vencord.Vesktop",
        "io.github.equicord.equibop",
    ];
    for index in 0..10 {
        let socket = format!("discord-ipc-{index}");
        let direct = root.join(&socket);
        if !candidates.contains(&direct) { candidates.push(direct); }
        for client_id in CLIENT_IDS {
            let nested = root.join("app").join(client_id).join(&socket);
            if !candidates.contains(&nested) { candidates.push(nested); }
        }
    }
}

#[cfg(unix)]
fn connect_discord_rpc(client_id: &str) -> Result<DiscordConnection, String> {
    let mut candidates = Vec::new();
    if let Some(explicit) = std::env::var_os("DISCORD_IPC_PATH") {
        candidates.push(PathBuf::from(explicit));
    }
    if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") {
        append_discord_socket_candidates(&mut candidates, &PathBuf::from(runtime));
    }
    if let Some(uid) = std::env::var_os("UID") {
        let root = PathBuf::from("/run/user").join(uid);
        append_discord_socket_candidates(&mut candidates, &root);
    }
    for index in 0..10 {
        let socket = PathBuf::from(format!("/tmp/discord-ipc-{index}"));
        if !candidates.contains(&socket) { candidates.push(socket); }
    }

    let mut last_error = None;
    for path in candidates {
        if !path.exists() { continue; }
        match UnixStream::connect(&path) {
            Ok(mut stream) => {
                stream.set_read_timeout(Some(Duration::from_secs(2))).ok();
                stream.set_write_timeout(Some(Duration::from_secs(2))).ok();
                let handshake = serde_json::json!({"v": 1, "client_id": client_id});
                write_discord_frame(&mut stream, 0, &handshake)?;
                let mut header = [0u8; 8];
                if let Err(error) = stream.read_exact(&mut header) {
                    last_error = Some(error.to_string());
                    continue;
                }
                let length = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
                if length > 64 * 1024 {
                    last_error = Some("Discord RPC handshake response was unexpectedly large".into());
                    continue;
                }
                let mut response = vec![0u8; length];
                if let Err(error) = stream.read_exact(&mut response) {
                    last_error = Some(error.to_string());
                    continue;
                }
                return Ok(DiscordConnection { client_id: client_id.to_string(), stream });
            }
            Err(error) => last_error = Some(error.to_string()),
        }
    }
    Err(last_error.unwrap_or_else(|| "No compatible Discord IPC socket was found. Open Discord, Vesktop or Equibop first.".into()))
}

#[cfg(unix)]
fn send_discord_presence(
    connection: &mut Option<DiscordConnection>,
    client_id: &str,
    details_template: &str,
    state_template: &str,
    custom_phrase: &str,
    title: &str,
    artist: &str,
    playback_state: &str,
) -> Result<(), String> {
    if client_id.trim().is_empty() {
        return Err("Discord Application Client ID is missing".into());
    }
    if connection.as_ref().map_or(true, |current| current.client_id != client_id) {
        *connection = Some(connect_discord_rpc(client_id)?);
    }
    let track_details = render_presence_template(details_template, title, artist);
    let phrase = render_presence_template(custom_phrase, title, artist);
    let details = if phrase.trim().is_empty() {
        track_details
    } else if track_details.trim().is_empty() {
        phrase
    } else {
        format!("{phrase} {track_details}")
    };
    let mut state = render_presence_template(state_template, title, artist);
    if playback_state == "Paused" {
        state = if state.trim().is_empty() { "Paused".into() } else { format!("{state} · Paused") };
    }
    let activity = serde_json::json!({
        "details": details.chars().take(128).collect::<String>(),
        "state": state.chars().take(128).collect::<String>(),
        "instance": false
    });
    let payload = serde_json::json!({
        "cmd": "SET_ACTIVITY",
        "args": { "pid": std::process::id(), "activity": activity },
        "nonce": Uuid::new_v4().to_string()
    });
    let current = connection.as_mut().expect("Discord connection was initialized");
    if let Err(error) = write_discord_frame(&mut current.stream, 1, &payload) {
        *connection = None;
        return Err(format!("Could not update Discord status: {error}"));
    }
    Ok(())
}

#[cfg(not(unix))]
fn send_discord_presence(
    _connection: &mut Option<DiscordConnection>,
    _client_id: &str,
    _details_template: &str,
    _state_template: &str,
    _custom_phrase: &str,
    _title: &str,
    _artist: &str,
    _playback_state: &str,
) -> Result<(), String> {
    Err("Discord Rich Presence is currently supported on Linux desktop clients only".into())
}

#[cfg(unix)]
fn clear_discord_presence(connection: &mut Option<DiscordConnection>) {
    if let Some(current) = connection.as_mut() {
        let payload = serde_json::json!({
            "cmd": "SET_ACTIVITY",
            "args": { "pid": std::process::id(), "activity": null },
            "nonce": Uuid::new_v4().to_string()
        });
        let _ = write_discord_frame(&mut current.stream, 1, &payload);
    }
    *connection = None;
}

#[cfg(not(unix))]
fn clear_discord_presence(_connection: &mut Option<DiscordConnection>) {}

fn update_discord_from_database(
    db: &Arc<Mutex<LibraryDatabase>>,
    connection: &Arc<Mutex<Option<DiscordConnection>>>,
    title: &str,
    artist: &str,
    playback_state: &str,
) {
    let db_lock = db.lock().unwrap();
    let enabled = db_lock.get_state_value("discord_presence_enabled").ok().flatten().as_deref() == Some("true");
    let client_id = db_lock.get_state_value("discord_client_id").ok().flatten().unwrap_or_default();
    let details = db_lock.get_state_value("discord_details_template").ok().flatten().unwrap_or_else(|| "Listening to {title}".into());
    let state = db_lock.get_state_value("discord_state_template").ok().flatten().unwrap_or_else(|| "by {artist}".into());
    let custom_phrase = db_lock.get_state_value("discord_custom_phrase").ok().flatten().unwrap_or_else(|| "Jamming out to".into());
    drop(db_lock);

    let mut connection = connection.lock().unwrap();
    if enabled {
        if let Err(error) = send_discord_presence(&mut connection, &client_id, &details, &state, &custom_phrase, title, artist, playback_state) {
            eprintln!("Raptor Music Discord Rich Presence: {error}");
        }
    } else {
        clear_discord_presence(&mut connection);
    }
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

fn parse_apple_music_tracks(payload: &serde_json::Value) -> Result<Vec<Track>, String> {
    let rows = payload.get("results")
        .and_then(|results| results.get("songs"))
        .and_then(|songs| songs.get("data"))
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "Apple Music returned an unexpected search response".to_string())?;

    let mut tracks = Vec::new();
    for row in rows.iter().take(25) {
        let Some(attributes) = row.get("attributes") else { continue; };
        let Some(provider_track_id) = row.get("id").and_then(serde_json::Value::as_str) else { continue; };
        let Some(title) = attributes.get("name").and_then(serde_json::Value::as_str) else { continue; };
        let Some(artist) = attributes.get("artistName").and_then(serde_json::Value::as_str) else { continue; };
        let preview_url = attributes.get("previews")
            .and_then(serde_json::Value::as_array)
            .and_then(|previews| previews.first())
            .and_then(|preview| preview.get("url"))
            .and_then(serde_json::Value::as_str);
        let Some(preview_url) = preview_url else { continue; };
        let Ok(parsed_url) = reqwest::Url::parse(preview_url) else { continue; };
        if parsed_url.scheme() != "https"
            || !matches!(parsed_url.host_str(), Some("audio-ssl.itunes.apple.com" | "audio.itunes.apple.com"))
        {
            continue;
        }
        let duration_secs = attributes.get("durationInMillis")
            .and_then(serde_json::Value::as_u64)
            .map(|millis| millis / 1000);
        let album = attributes.get("albumName")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(|value| format!("{value} · Apple Music preview"));
        let stable_id = Uuid::new_v5(
            &Uuid::NAMESPACE_URL,
            format!("raptor-music:apple-music:{provider_track_id}").as_bytes(),
        );
        tracks.push(Track {
            id: stable_id,
            title: title.to_string(),
            artist: artist.to_string(),
            album,
            duration_secs,
            source: PlaybackSource::RemoteStream {
                provider_id: "apple_music_preview".into(),
                provider_track_id: preview_url.to_string(),
            },
        });
    }
    Ok(tracks)
}


fn parse_jamendo_tracks(payload: &serde_json::Value) -> Result<Vec<Track>, String> {
    let rows = payload.get("results").and_then(serde_json::Value::as_array)
        .ok_or_else(|| "Jamendo returned an unexpected search response".to_string())?;
    let mut tracks = Vec::new();
    for row in rows.iter().take(25) {
        let Some(provider_track_id) = row.get("id").and_then(serde_json::Value::as_str) else { continue; };
        if provider_track_id.is_empty() || !provider_track_id.chars().all(|ch| ch.is_ascii_digit()) { continue; }
        let Some(title) = row.get("name").and_then(serde_json::Value::as_str).filter(|value| !value.trim().is_empty()) else { continue; };
        let Some(artist) = row.get("artist_name").and_then(serde_json::Value::as_str).filter(|value| !value.trim().is_empty()) else { continue; };
        let Some(license) = row.get("license_ccurl").and_then(serde_json::Value::as_str) else { continue; };
        let Ok(license_url) = reqwest::Url::parse(license) else { continue; };
        if license_url.host_str() != Some("creativecommons.org") { continue; }
        let duration_secs = row.get("duration").and_then(serde_json::Value::as_u64);
        let album = row.get("album_name").and_then(serde_json::Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(|value| format!("{value} · Jamendo · CC"))
            .or_else(|| Some("Jamendo · Creative Commons".into()));
        let stable_id = Uuid::new_v5(
            &Uuid::NAMESPACE_URL,
            format!("raptor-music:jamendo:{provider_track_id}").as_bytes(),
        );
        tracks.push(Track {
            id: stable_id,
            title: title.to_string(),
            artist: artist.to_string(),
            album,
            duration_secs,
            source: PlaybackSource::RemoteStream {
                provider_id: "jamendo_external".into(),
                provider_track_id: provider_track_id.to_string(),
            },
        });
    }
    Ok(tracks)
}

fn search_jamendo_tracks(query: &str) -> Result<Vec<Track>, String> {
    let client_id = std::env::var("RAPTOR_JAMENDO_CLIENT_ID")
        .map_err(|_| "Jamendo catalog not configured · set RAPTOR_JAMENDO_CLIENT_ID".to_string())?;
    let client_id = client_id.trim();
    if client_id.is_empty() {
        return Err("Jamendo catalog client ID is empty".into());
    }
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| format!("Could not initialize Jamendo search: {error}"))?;
    let response = client.get("https://api.jamendo.com/v3.0/tracks/")
        .query(&[
            ("client_id", client_id),
            ("format", "json"),
            ("limit", "50"),
            ("search", query.trim()),
            ("include", "licenses"),
            ("type", "single albumtrack"),
        ])
        .send()
        .and_then(|response| response.error_for_status())
        .map_err(|error| format!("Jamendo catalog search failed: {error}"))?;
    let payload: serde_json::Value = response.json()
        .map_err(|error| format!("Jamendo returned unreadable search results: {error}"))?;
    parse_jamendo_tracks(&payload)
}

fn open_jamendo_track(track_id: &str) -> Result<(), String> {
    if track_id.is_empty() || !track_id.chars().all(|ch| ch.is_ascii_digit()) {
        return Err("Jamendo returned an invalid track identifier".into());
    }
    let url = format!("https://www.jamendo.com/track/{track_id}");
    std::process::Command::new("gio").arg("open").arg(url).spawn()
        .map_err(|_| "Could not open this track on Jamendo in the system browser".to_string())?;
    Ok(())
}

fn search_apple_music_tracks(query: &str) -> Result<Vec<Track>, String> {
    let developer_token = std::env::var("RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN")
        .map_err(|_| "Apple Music catalog needs a developer token".to_string())?;
    let developer_token = developer_token.trim();
    if developer_token.is_empty() {
        return Err("Apple Music developer token is empty".to_string());
    }
    let storefront = std::env::var("RAPTOR_APPLE_MUSIC_STOREFRONT")
        .unwrap_or_else(|_| "us".to_string())
        .to_lowercase();
    if storefront.len() != 2 || !storefront.chars().all(|ch| ch.is_ascii_lowercase()) {
        return Err("Apple Music storefront must be a two-letter country code".to_string());
    }
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| format!("Could not initialize Apple Music search: {error}"))?;
    let response = client.get(format!("https://api.music.apple.com/v1/catalog/{storefront}/search"))
        .bearer_auth(developer_token)
        .query(&[("term", query.trim()), ("types", "songs"), ("limit", "25")])
        .send()
        .and_then(|response| response.error_for_status())
        .map_err(|error| format!("Apple Music catalog search failed: {error}"))?;
    let payload: serde_json::Value = response.json()
        .map_err(|error| format!("Apple Music returned unreadable search results: {error}"))?;
    parse_apple_music_tracks(&payload)
}


fn apple_music_api_client() -> Result<reqwest::blocking::Client, String> {
    reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18")
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|error| format!("Could not initialize Apple Music library access: {error}"))
}

fn apple_music_api_get(
    client: &reqwest::blocking::Client,
    url: &reqwest::Url,
    developer_token: &str,
    user_token: &str,
) -> Result<serde_json::Value, String> {
    if url.scheme() != "https" || url.host_str() != Some("api.music.apple.com")
        || !url.path().starts_with("/v1/me/")
        || !url.username().is_empty() || url.password().is_some()
    {
        return Err("Apple Music returned an untrusted library pagination URL".into());
    }
    let response = client.get(url.clone())
        .bearer_auth(developer_token)
        .header("Music-User-Token", user_token)
        .send()
        .map_err(|error| format!("Apple Music library request failed: {error}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("Apple Music library request returned HTTP {status}"));
    }
    response.json::<serde_json::Value>()
        .map_err(|error| format!("Apple Music returned unreadable library data: {error}"))
}

fn apple_music_resource_pages(
    client: &reqwest::blocking::Client,
    initial_url: reqwest::Url,
    developer_token: &str,
    user_token: &str,
) -> Result<Vec<serde_json::Value>, String> {
    let mut page_url = Some(initial_url);
    let mut seen = HashSet::new();
    let mut resources = Vec::new();
    for _ in 0..100 {
        let Some(url) = page_url.take() else { break; };
        let key = url.as_str().to_string();
        if !seen.insert(key) {
            return Err("Apple Music repeated a library pagination URL".into());
        }
        let payload = apple_music_api_get(client, &url, developer_token, user_token)?;
        if let Some(rows) = payload.get("data").and_then(serde_json::Value::as_array) {
            for row in rows {
                if resources.len() >= 20_000 { return Err("Apple Music library exceeded the 20,000-item safety limit".into()); }
                resources.push(row.clone());
            }
        }
        if let Some(next) = payload.get("next").and_then(serde_json::Value::as_str) {
            page_url = Some(apple_music_pagination_url(&url, next)?);
        }
    }
    if page_url.is_some() {
        return Err("Apple Music library pagination exceeded its page safety limit".into());
    }
    Ok(resources)
}

fn apple_music_pagination_url(current: &reqwest::Url, next: &str) -> Result<reqwest::Url, String> {
    let parsed = current.join(next)
        .map_err(|_| "Apple Music returned an invalid pagination link".to_string())?;
    if parsed.scheme() != "https"
        || parsed.host_str() != Some("api.music.apple.com")
        || parsed.port_or_known_default() != Some(443)
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || !parsed.path().starts_with("/v1/me/")
    {
        return Err("Apple Music returned an untrusted pagination destination".into());
    }
    Ok(parsed)
}

fn apple_music_initial_url(path: &str) -> Result<reqwest::Url, String> {
    reqwest::Url::parse(&format!("https://api.music.apple.com/v1/me/{path}"))
        .map_err(|_| "Could not construct Apple Music library endpoint".into())
}

fn apple_music_track_from_resource(row: &serde_json::Value) -> Option<profile_import::ImportedTrack> {
    let attributes = row.get("attributes")?;
    let title = attributes.get("name")?.as_str()?.trim();
    let artist = attributes.get("artistName").and_then(serde_json::Value::as_str).unwrap_or("Unknown artist").trim();
    if title.is_empty() || artist.is_empty() { return None; }
    Some(profile_import::ImportedTrack {
        source_id: row.get("id").and_then(serde_json::Value::as_str).map(str::to_owned),
        title: title.to_string(),
        artist: artist.to_string(),
        album: attributes.get("albumName").and_then(serde_json::Value::as_str).map(str::to_owned),
    })
}

fn apple_music_artwork_url(attributes: &serde_json::Value) -> Option<String> {
    let template = attributes.pointer("/artwork/url")?.as_str()?;
    let url = template.replace("{w}", "512").replace("{h}", "512");
    let parsed = reqwest::Url::parse(&url).ok()?;
    if parsed.scheme() == "https" && matches!(parsed.host_str(), Some("is1-ssl.mzstatic.com" | "is2-ssl.mzstatic.com" | "is3-ssl.mzstatic.com" | "is4-ssl.mzstatic.com" | "is5-ssl.mzstatic.com")) {
        Some(url)
    } else { None }
}

fn fetch_apple_music_library_import(
    developer_token: &str,
    user_token: &str,
) -> Result<(profile_import::ImportedProfile, Vec<String>), String> {
    let client = apple_music_api_client()?;
    let mut profile = profile_import::ImportedProfile {
        source: "Apple Music".into(),
        display_name: Some("Apple Music Library".into()),
        ..profile_import::ImportedProfile::default()
    };
    let mut warnings = Vec::new();

    match apple_music_resource_pages(
        &client, apple_music_initial_url("library/songs?limit=100")?,
        developer_token, user_token,
    ) {
        Ok(songs) => profile.saved_tracks = songs.iter().filter_map(apple_music_track_from_resource).collect(),
        Err(error) => warnings.push(format!("Library songs: {error}")),
    }

    let playlists = match apple_music_resource_pages(
        &client, apple_music_initial_url("library/playlists?limit=100")?,
        developer_token, user_token,
    ) {
        Ok(rows) => rows,
        Err(error) => { warnings.push(format!("Playlists: {error}")); Vec::new() }
    };
    let mut track_budget = 50_000usize;
    for playlist in playlists.into_iter().take(500) {
        let Some(id) = playlist.get("id").and_then(serde_json::Value::as_str) else { continue; };
        let attributes = playlist.get("attributes").cloned().unwrap_or_default();
        let name = attributes.get("name").and_then(serde_json::Value::as_str).unwrap_or("Untitled playlist").trim();
        if name.is_empty() { continue; }
        let mut tracks = Vec::new();
        if track_budget > 0 {
            let mut endpoint = apple_music_initial_url("library/playlists/")?;
            {
                let mut segments = endpoint.path_segments_mut().map_err(|_| "Could not build Apple Music playlist URL")?;
                segments.pop_if_empty();
                segments.push(id);
                segments.push("tracks");
            }
            endpoint.query_pairs_mut().append_pair("limit", "100");
            match apple_music_resource_pages(&client, endpoint, developer_token, user_token) {
                Ok(rows) => {
                    tracks = rows.iter().filter_map(apple_music_track_from_resource)
                        .take(track_budget).collect();
                    track_budget = track_budget.saturating_sub(tracks.len());
                }
                Err(error) => warnings.push(format!("Playlist {name}: {error}")),
            }
        }
        let description = attributes.pointer("/description/standard")
            .and_then(serde_json::Value::as_str)
            .or_else(|| attributes.get("description").and_then(serde_json::Value::as_str))
            .filter(|value| !value.trim().is_empty()).map(str::to_owned);
        profile.playlists.push(profile_import::ImportedPlaylist {
            source_id: Some(id.to_string()),
            name: name.to_string(),
            description,
            artwork_url: apple_music_artwork_url(&attributes),
            tracks,
        });
    }

    match apple_music_resource_pages(
        &client, apple_music_initial_url("library/artists?limit=100")?,
        developer_token, user_token,
    ) {
        Ok(rows) => {
            profile.library_artists = rows.iter().filter_map(|row| {
                let name = row.pointer("/attributes/name")?.as_str()?.trim();
                if name.is_empty() { return None; }
                Some(profile_import::ImportedArtist {
                    source_id: row.get("id").and_then(serde_json::Value::as_str).map(str::to_owned),
                    name: name.to_string(),
                })
            }).collect();
        }
        Err(error) => warnings.push(format!("Library artists: {error}")),
    }
    match apple_music_resource_pages(
        &client, apple_music_initial_url("recent/played/tracks?limit=30&types=songs")?,
        developer_token, user_token,
    ) {
        Ok(rows) => {
            profile.listening_history = rows.iter().filter_map(apple_music_track_from_resource)
                .map(|track| profile_import::ImportedListen {
                    track,
                    // Apple's recent-played endpoint returns the ordered recent
                    // resources, but not a per-item playback timestamp.
                    played_at: None,
                    ms_played: None,
                    play_count: 1,
                }).collect();
        }
        Err(error) => warnings.push(format!("Recent listening: {error}")),
    }
    Ok((profile, warnings))
}

fn save_apple_music_library_import(
    imported: profile_import::ImportedProfile,
    warnings: Vec<String>,
    db: &Arc<Mutex<LibraryDatabase>>,
    ui: &slint::Weak<MainWindow>,
    action: &str,
) -> Result<String, String> {
    let playlist_count = imported.playlists.len();
    let playlist_track_count: usize = imported.playlists.iter().map(|playlist| playlist.tracks.len()).sum();
    let saved_count = imported.saved_tracks.len();
    let library_artist_count = imported.library_artists.len();
    let recent_count = imported.listening_history.len();
    let payload = serde_json::to_string(&imported)
        .map_err(|_| "Could not prepare the Apple Music library import".to_string())?;
    db.lock().map_err(|_| "The local profile database is unavailable".to_string())?
        // One connected Apple Music account is active per desktop profile.
        // A stable local key makes Refresh Library update, not duplicate, its import.
        .save_imported_profile("apple_music", imported.display_name.as_deref(), Some("connected-account"), &payload)
        .map_err(|error| format!("Could not save Apple Music library: {error}"))?;
    let ui_refresh = ui.clone();
    let db_refresh = Arc::clone(db);
    let _ = slint::invoke_from_event_loop(move || {
        if let Some(ui) = ui_refresh.upgrade() { refresh_imported_profile_list(&ui, &db_refresh); }
    });
    let warning_text = if warnings.is_empty() { String::new() } else { format!(" Some sections were unavailable: {}.", warnings.join(" · ")) };
    Ok(format!(
        "Apple Music {action}: {saved_count} library songs · {playlist_count} playlists · {playlist_track_count} playlist tracks · {library_artist_count} library artists · {recent_count} recent plays.{warning_text}"
    ))
}

fn start_apple_music_connection(ui: slint::Weak<MainWindow>, db: Arc<Mutex<LibraryDatabase>>) {
    std::thread::spawn(move || {
        let result = (|| -> Result<String, String> {
            let developer_token = std::env::var("RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN")
                .map_err(|_| "Set RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN before connecting Apple Music".to_string())?;
            let listener = apple_music_auth::AppleMusicAuthListener::bind(&developer_token)?;
            std::process::Command::new("gio").arg("open").arg(listener.authorization_url()).spawn()
                .map_err(|_| "Could not open the system browser for Apple Music authorization".to_string())?;
            let user_token = listener.wait_for_user_token(Duration::from_secs(240))?;
            token_store::save_music_user_token(&user_token)?;
            let (imported, warnings) = fetch_apple_music_library_import(&developer_token, &user_token)
                .map_err(|error| format!("Authorization was saved securely, but library import failed: {error}"))?;
            save_apple_music_library_import(imported, warnings, &db, &ui, "connected and imported")
        })();
        let status = result.unwrap_or_else(|error| format!("Apple Music connection failed: {error}"));
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = ui.upgrade() { ui.set_provider_connection_status(status.into()); }
        });
    });
}

fn start_apple_music_library_refresh(ui: slint::Weak<MainWindow>, db: Arc<Mutex<LibraryDatabase>>) {
    std::thread::spawn(move || {
        let result = (|| -> Result<String, String> {
            let developer_token = std::env::var("RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN")
                .map_err(|_| "Set RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN before refreshing Apple Music".to_string())?;
            let user_token = token_store::load_music_user_token()
                .map_err(|_| "Connect Apple Music before refreshing its library".to_string())?;
            let (imported, warnings) = fetch_apple_music_library_import(&developer_token, &user_token)?;
            save_apple_music_library_import(imported, warnings, &db, &ui, "library refreshed")
        })();
        let status = result.unwrap_or_else(|error| format!("Apple Music refresh failed: {error}"));
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(ui) = ui.upgrade() { ui.set_provider_connection_status(status.into()); }
        });
    });
}

fn normalized_sort_method(value: &str) -> &'static str {
    match value {
        "popular" => "popular",
        "recent" => "recent",
        "independent" => "relevant",
        _ => "relevant",
    }
}

fn parse_audius_collections(payload: &serde_json::Value) -> Result<Vec<AudiusCollection>, String> {
    let data = payload.get("data")
        .ok_or_else(|| "Audius returned an unexpected collection search response".to_string())?;
    let mut collections = Vec::new();
    for (key, kind) in [("albums", "Album"), ("playlists", "Playlist")] {
        let Some(rows) = data.get(key).and_then(serde_json::Value::as_array) else { continue; };
        for row in rows.iter().take(20) {
            let Some(id) = row.get("id").and_then(serde_json::Value::as_str) else { continue; };
            if id.is_empty() || !id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_') { continue; }
            if row.get("is_private").and_then(serde_json::Value::as_bool) == Some(true)
                || row.get("is_delete").and_then(serde_json::Value::as_bool) == Some(true) { continue; }
            let title = row.get("playlist_name").and_then(serde_json::Value::as_str)
                .or_else(|| row.get("title").and_then(serde_json::Value::as_str))
                .filter(|value| !value.trim().is_empty());
            let Some(title) = title else { continue; };
            let creator = row.get("user").and_then(|user| user.get("name"))
                .and_then(serde_json::Value::as_str).unwrap_or("Unknown artist");
            collections.push(AudiusCollection {
                id: id.to_string(), title: title.to_string(), creator: creator.to_string(), kind: kind.to_string(),
                provider: "audius".into(), external_url: None,
            });
        }
    }
    Ok(collections)
}

fn parse_apple_music_collections(payload: &serde_json::Value) -> Result<Vec<AudiusCollection>, String> {
    let results = payload.get("results")
        .ok_or_else(|| "Apple Music returned an unexpected collection search response".to_string())?;
    let mut collections = Vec::new();
    for (key, kind) in [("albums", "Album"), ("playlists", "Playlist")] {
        let Some(rows) = results.get(key).and_then(serde_json::Value::as_object)
            .and_then(|group| group.get("data")).and_then(serde_json::Value::as_array) else { continue; };
        for row in rows.iter().take(25) {
            let Some(id) = row.get("id").and_then(serde_json::Value::as_str).map(str::trim) else { continue; };
            let Some(attributes) = row.get("attributes") else { continue; };
            let Some(title) = attributes.get("name").and_then(serde_json::Value::as_str).map(str::trim) else { continue; };
            let Some(url) = attributes.get("url").and_then(serde_json::Value::as_str)
                .and_then(apple_music_web_url) else { continue; };
            if id.is_empty() || title.is_empty() || id.len() > 128
                || !id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_') { continue; }
            let creator = attributes.get("artistName").and_then(serde_json::Value::as_str)
                .filter(|name| !name.trim().is_empty()).unwrap_or("Apple Music");
            collections.push(AudiusCollection {
                id: id.to_string(), title: title.to_string(), creator: creator.to_string(),
                kind: kind.to_string(), provider: "apple_music".into(), external_url: Some(url),
            });
        }
    }
    Ok(collections)
}

fn search_apple_music_collections(query: &str) -> Result<Vec<AudiusCollection>, String> {
    let developer_token = std::env::var("RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN")
        .map_err(|_| "Apple Music catalog needs a developer token".to_string())?;
    if developer_token.trim().is_empty() {
        return Err("Apple Music developer token is empty".into());
    }
    let storefront = std::env::var("RAPTOR_APPLE_MUSIC_STOREFRONT")
        .unwrap_or_else(|_| "us".into()).to_lowercase();
    if storefront.len() != 2 || !storefront.chars().all(|ch| ch.is_ascii_lowercase()) {
        return Err("Apple Music storefront must be a two-letter country code".into());
    }
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.19")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build().map_err(|error| format!("Could not initialize Apple Music collection search: {error}"))?;
    let response = client.get(format!("https://api.music.apple.com/v1/catalog/{storefront}/search"))
        .bearer_auth(developer_token.trim())
        .query(&[("term", query.trim()), ("types", "albums,playlists"), ("limit", "25")])
        .send().and_then(|response| response.error_for_status())
        .map_err(|error| format!("Apple Music album and playlist search failed: {error}"))?;
    let payload: serde_json::Value = response.json()
        .map_err(|error| format!("Apple Music returned unreadable collection results: {error}"))?;
    parse_apple_music_collections(&payload)
}

fn search_audius_collections(query: &str) -> Result<Vec<AudiusCollection>, String> {
    let query = query.trim();
    if query.is_empty() { return Ok(Vec::new()); }
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build().map_err(|error| format!("Could not initialize collection search: {error}"))?;
    let response = client.get("https://api.audius.co/v1/search/autocomplete")
        .query(&[("query", query), ("app_name", "RaptorMusic")])
        .send().and_then(|response| response.error_for_status())
        .map_err(|error| format!("Audius album and playlist search failed: {error}"))?;
    let payload: serde_json::Value = response.json()
        .map_err(|error| format!("Audius returned unreadable collection results: {error}"))?;
    parse_audius_collections(&payload)
}

fn fetch_audius_collection_tracks(collection: &AudiusCollection) -> Result<Vec<Track>, String> {
    if collection.id.is_empty()
        || !collection.id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_') {
        return Err("Invalid album or playlist identifier".to_string());
    }
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build().map_err(|error| format!("Could not initialize collection request: {error}"))?;
    let response = client.get(format!("https://api.audius.co/v1/playlists/{}/tracks", collection.id))
        .query(&[("app_name", "RaptorMusic")])
        .send().and_then(|response| response.error_for_status())
        .map_err(|error| format!("Could not load {}: {error}", collection.title))?;
    let payload: serde_json::Value = response.json()
        .map_err(|error| format!("Audius returned unreadable collection tracks: {error}"))?;
    parse_audius_tracks(&payload)
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
        Some(AudiusArtist { id, name, handle, provider: "audius".into(), external_url: None })
    }).collect())
}


fn apple_music_web_url(value: &str) -> Option<String> {
    let url = reqwest::Url::parse(value).ok()?;
    if url.scheme() == "https" && url.host_str() == Some("music.apple.com")
        && url.port_or_known_default() == Some(443)
        && url.username().is_empty() && url.password().is_none()
    {
        Some(url.to_string())
    } else { None }
}

fn apple_music_catalog_pagination_url(
    endpoint: &str, next: &str, storefront: &str, artist_id: &str
) -> Result<String, String> {
    let base = reqwest::Url::parse(endpoint)
        .map_err(|_| "Apple Music catalog pagination base URL is invalid".to_string())?;
    let url = base.join(next)
        .map_err(|_| "Apple Music catalog returned an invalid pagination URL".to_string())?;
    let expected_path = format!("/v1/catalog/{storefront}/artists/{artist_id}/albums");
    if url.scheme() != "https" || url.host_str() != Some("api.music.apple.com")
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty() || url.password().is_some()
        || url.path() != expected_path || url.fragment().is_some()
    {
        return Err("Apple Music returned an untrusted catalog pagination URL".to_string());
    }
    Ok(url.to_string())
}

fn apple_music_artist_discography(artist: &AudiusArtist) -> Result<Vec<AudiusCollection>, String> {
    if artist.provider != "apple_music" || artist.id.is_empty()
        || !artist.id.chars().all(|ch| ch.is_ascii_digit()) {
        return Err("Invalid Apple Music artist identifier".to_string());
    }
    let developer_token = std::env::var("RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN")
        .map_err(|_| "Apple Music catalog needs a developer token".to_string())?;
    if developer_token.trim().is_empty() { return Err("Apple Music developer token is empty".into()); }
    let storefront = std::env::var("RAPTOR_APPLE_MUSIC_STOREFRONT")
        .unwrap_or_else(|_| "us".into()).to_lowercase();
    if storefront.len() != 2 || !storefront.chars().all(|ch| ch.is_ascii_lowercase()) {
        return Err("Apple Music storefront must be a two-letter country code".into());
    }
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.19").connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15)).redirect(reqwest::redirect::Policy::none()).build()
        .map_err(|error| format!("Could not initialize Apple Music discography request: {error}"))?;
    let endpoint = format!("https://api.music.apple.com/v1/catalog/{storefront}/artists/{}/albums", artist.id);
    let mut next_url = Some(endpoint.clone());
    let mut albums = Vec::new();
    for _page in 0..4 {
        let Some(url) = next_url.take() else { break; };
        let response = client.get(&url).bearer_auth(developer_token.trim())
            .query(if url == endpoint { &[("limit", "25")][..] } else { &[][..] })
            .send().and_then(|response| response.error_for_status())
            .map_err(|error| format!("Apple Music artist albums request failed: {error}"))?;
        let payload: serde_json::Value = response.json()
            .map_err(|error| format!("Apple Music artist albums response was unreadable: {error}"))?;
        let normalized = serde_json::json!({"results":{"albums":{"data":payload.get("data").cloned().unwrap_or_else(|| serde_json::Value::Array(Vec::new()))}}});
        albums.extend(parse_apple_music_collections(&normalized)?);
        next_url = payload.get("next").and_then(serde_json::Value::as_str)
            .map(|next| apple_music_catalog_pagination_url(&endpoint, next, &storefront, &artist.id))
            .transpose()?;
    }
    albums.retain(|album| album.provider == "apple_music");
    let mut seen = HashSet::new();
    albums.retain(|album| seen.insert(album.id.clone()));
    Ok(albums)
}

fn search_apple_music_artists(query: &str) -> Result<Vec<AudiusArtist>, String> {
    let developer_token = std::env::var("RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN")
        .map_err(|_| "Apple Music catalog needs a developer token".to_string())?;
    if developer_token.trim().is_empty() { return Err("Apple Music developer token is empty".into()); }
    let storefront = std::env::var("RAPTOR_APPLE_MUSIC_STOREFRONT")
        .unwrap_or_else(|_| "us".into()).to_lowercase();
    if storefront.len() != 2 || !storefront.chars().all(|ch| ch.is_ascii_lowercase()) {
        return Err("Apple Music storefront must be a two-letter country code".into());
    }
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18")
        .connect_timeout(Duration::from_secs(8))
        .timeout(Duration::from_secs(15))
        .build().map_err(|error| format!("Could not initialize Apple Music artist search: {error}"))?;
    let response = client.get(format!("https://api.music.apple.com/v1/catalog/{storefront}/search"))
        .bearer_auth(developer_token.trim())
        .query(&[("term", query.trim()), ("types", "artists"), ("limit", "25")])
        .send().and_then(|response| response.error_for_status())
        .map_err(|error| format!("Apple Music artist search failed: {error}"))?;
    let payload: serde_json::Value = response.json()
        .map_err(|error| format!("Apple Music returned unreadable artist results: {error}"))?;
    let rows = payload.pointer("/results/artists/data").and_then(serde_json::Value::as_array)
        .ok_or_else(|| "Apple Music returned an unexpected artist search response".to_string())?;
    Ok(rows.iter().filter_map(|row| {
        let id = row.get("id")?.as_str()?.trim();
        let attributes = row.get("attributes")?;
        let name = attributes.get("name")?.as_str()?.trim();
        let url = apple_music_web_url(attributes.get("url")?.as_str()?)?;
        if id.is_empty() || name.is_empty() { return None; }
        Some(AudiusArtist {
            id: id.to_string(),
            name: name.to_string(),
            handle: "Apple Music".into(),
            provider: "apple_music".into(),
            external_url: Some(url),
        })
    }).collect())
}

fn musicbrainz_web_url(value: &str) -> Option<String> {
    let url = reqwest::Url::parse(value).ok()?;
    let path = url.path();
    if url.scheme() == "https" && url.host_str() == Some("musicbrainz.org")
        && url.port_or_known_default() == Some(443)
        && url.username().is_empty() && url.password().is_none()
        && (path.starts_with("/artist/") || path.starts_with("/release-group/"))
    {
        Uuid::parse_str(path.rsplit('/').next()?).ok()?;
        Some(url.to_string())
    } else { None }
}

fn open_musicbrainz_link(url: &str) -> Result<(), String> {
    let safe_url = musicbrainz_web_url(url).ok_or_else(|| "MusicBrainz returned an untrusted destination".to_string())?;
    std::process::Command::new("gio").arg("open").arg(safe_url).spawn()
        .map_err(|_| "Could not open MusicBrainz in the system browser".to_string())?;
    Ok(())
}

fn musicbrainz_search(query: &str, entity: &str) -> Result<serde_json::Value, String> {
    musicbrainz_search_page(query, entity, 0)
}

fn musicbrainz_search_page(
    query: &str,
    entity: &str,
    offset: u64,
) -> Result<serde_json::Value, String> {
    // MusicBrainz asks clients to stay at or below one request per second.
    // Keep the lock across waiting and the complete request so concurrent
    // searches cannot accidentally exceed the service's shared rate limit.
    static REQUEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    static LAST_REQUEST: std::sync::Mutex<Option<Instant>> = std::sync::Mutex::new(None);
    let _guard = REQUEST_LOCK.lock().map_err(|_| "MusicBrainz request lock is unavailable".to_string())?;
    if let Some(last) = *LAST_REQUEST.lock().map_err(|_| "MusicBrainz rate-limit state is unavailable".to_string())? {
        let elapsed = last.elapsed();
        if elapsed < Duration::from_millis(1100) { std::thread::sleep(Duration::from_millis(1100) - elapsed); }
    }
    *LAST_REQUEST.lock().map_err(|_| "MusicBrainz rate-limit state is unavailable".to_string())? = Some(Instant::now());
    let client = reqwest::blocking::Client::builder()
        .user_agent("RaptorMusic/0.2.18 (https://github.com/Cerberus9-dev/Raptor-OS-Home-Edition)")
        .connect_timeout(Duration::from_secs(8)).timeout(Duration::from_secs(15))
        .redirect(reqwest::redirect::Policy::none()).build()
        .map_err(|error| format!("Could not initialize MusicBrainz catalog: {error}"))?;
    client.get(format!("https://musicbrainz.org/ws/2/{entity}"))
        .query(&[("query", query), ("fmt", "json"), ("limit", "100"), ("offset", &offset.to_string())])
        .send().and_then(|response| response.error_for_status())
        .map_err(|error| format!("MusicBrainz {entity} search failed: {error}"))?
        .json().map_err(|error| format!("MusicBrainz {entity} response was unreadable: {error}"))
}

fn search_musicbrainz_artists(query: &str) -> Result<Vec<AudiusArtist>, String> {
    let query = query.trim();
    if query.len() < 2 { return Ok(Vec::new()); }
    let payload = musicbrainz_search(&format!("artist:{query}"), "artist")?;
    let rows = payload.get("artists").and_then(serde_json::Value::as_array)
        .ok_or_else(|| "MusicBrainz returned an unexpected artist response".to_string())?;
    Ok(rows.iter().filter_map(|row| {
        let id = row.get("id")?.as_str()?;
        Uuid::parse_str(id).ok()?;
        let name = row.get("name")?.as_str()?.trim();
        if name.is_empty() { return None; }
        let disambiguation = row.get("disambiguation").and_then(serde_json::Value::as_str).unwrap_or("");
        Some(AudiusArtist { id: id.into(), name: name.into(),
            handle: if disambiguation.is_empty() { "MusicBrainz".into() } else { format!("MusicBrainz · {disambiguation}") },
            provider: "musicbrainz".into(),
            external_url: musicbrainz_web_url(&format!("https://musicbrainz.org/artist/{id}")) })
    }).collect())
}

fn musicbrainz_artist_discography(artist: &AudiusArtist) -> Result<Vec<AudiusCollection>, String> {
    if artist.provider != "musicbrainz" || Uuid::parse_str(&artist.id).is_err() {
        return Err("Invalid MusicBrainz artist identifier".to_string());
    }

    // Release-group searches are capped at 100 rows per request. Follow the
    // reported count in sequential, rate-limited pages, with a hard ceiling
    // so unusually large or malformed catalogs cannot stall the UI forever.
    let query = format!("arid:{}", artist.id);
    let first_page = musicbrainz_search_page(&query, "release-group", 0)?;
    let reported_count = first_page.get("release-group-count")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or_else(|| first_page.get("release-groups")
            .and_then(serde_json::Value::as_array)
            .map(|rows| rows.len() as u64)
            .unwrap_or(0));
    let mut pages = vec![first_page];
    let page_limit = reported_count.min(500);
    let mut offset = 100_u64;
    while offset < page_limit {
        pages.push(musicbrainz_search_page(&query, "release-group", offset)?);
        offset += 100;
    }
    let payload = merge_musicbrainz_release_group_pages(pages)?;
    parse_musicbrainz_release_groups(&payload)
}

fn merge_musicbrainz_release_group_pages(
    pages: Vec<serde_json::Value>,
) -> Result<serde_json::Value, String> {
    let mut merged = Vec::new();
    let mut seen = HashSet::new();
    let mut reported_count = 0_u64;
    for page in pages {
        if let Some(count) = page.get("release-group-count").and_then(serde_json::Value::as_u64) {
            reported_count = reported_count.max(count);
        }
        let rows = page.get("release-groups").and_then(serde_json::Value::as_array)
            .ok_or_else(|| "MusicBrainz returned an unexpected release page".to_string())?;
        for row in rows {
            let id = row.get("id").and_then(serde_json::Value::as_str)
                .ok_or_else(|| "MusicBrainz returned a release without an identifier".to_string())?;
            if seen.insert(id.to_string()) {
                merged.push(row.clone());
            }
        }
    }
    Ok(serde_json::json!({
        "release-group-count": reported_count,
        "release-groups": merged
    }))
}

fn search_musicbrainz_collections(query: &str) -> Result<Vec<AudiusCollection>, String> {
    let query = query.trim();
    if query.len() < 2 { return Ok(Vec::new()); }
    let payload = musicbrainz_search(query, "release-group")?;
    parse_musicbrainz_release_groups(&payload)
}

fn parse_musicbrainz_release_groups(payload: &serde_json::Value) -> Result<Vec<AudiusCollection>, String> {
    let rows = payload.get("release-groups").and_then(serde_json::Value::as_array)
        .ok_or_else(|| "MusicBrainz returned an unexpected release response".to_string())?;
    let mut ordered_rows = rows.iter().collect::<Vec<_>>();
    ordered_rows.sort_by(|left, right| {
        let left_date = left.get("first-release-date").and_then(serde_json::Value::as_str).unwrap_or("");
        let right_date = right.get("first-release-date").and_then(serde_json::Value::as_str).unwrap_or("");
        right_date.cmp(left_date)
    });
    let mut seen = HashSet::new();
    Ok(ordered_rows.into_iter().filter_map(|row| {
        let id = row.get("id")?.as_str()?;
        Uuid::parse_str(id).ok()?;
        if !seen.insert(id.to_string()) { return None; }
        let title = row.get("title")?.as_str()?.trim();
        if title.is_empty() { return None; }
        let creator = row.get("artist-credit").and_then(serde_json::Value::as_array)
            .and_then(|credits| credits.first())
            .and_then(|credit| credit.get("name").or_else(|| credit.get("artist").and_then(|artist| artist.get("name"))))
            .and_then(serde_json::Value::as_str).unwrap_or("Various artists");
        let kind = row.get("primary-type").and_then(serde_json::Value::as_str).unwrap_or("Release");
        let date = row.get("first-release-date").and_then(serde_json::Value::as_str).unwrap_or("");
        Some(AudiusCollection { id: id.into(), title: title.into(),
            creator: if date.is_empty() { creator.into() } else { format!("{creator} · {date}") },
            kind: kind.into(), provider: "musicbrainz".into(),
            external_url: musicbrainz_web_url(&format!("https://musicbrainz.org/release-group/{id}")) })
    }).collect())
}

fn open_apple_music_link(url: &str) -> Result<(), String> {
    let safe_url = apple_music_web_url(url)
        .ok_or_else(|| "Apple Music returned an untrusted destination".to_string())?;
    std::process::Command::new("gio").arg("open").arg(safe_url).spawn()
        .map_err(|_| "Could not open Apple Music in the system browser".to_string())?;
    Ok(())
}

fn parse_audius_artist_albums(payload: &serde_json::Value, artist_name: &str) -> Result<Vec<AudiusCollection>, String> {
    let rows = payload.get("data").and_then(serde_json::Value::as_array)
        .ok_or_else(|| "Audius artist albums response had an unexpected shape".to_string())?;
    let mut albums = Vec::new();
    let mut seen = HashSet::new();
    for row in rows {
        let Some(id) = row.get("id").and_then(serde_json::Value::as_str) else { continue; };
        if id.is_empty() || !id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_') { continue; }
        if !seen.insert(id.to_string()) { continue; }
        let title = row.get("playlist_name").and_then(serde_json::Value::as_str)
            .or_else(|| row.get("title").and_then(serde_json::Value::as_str))
            .or_else(|| row.get("name").and_then(serde_json::Value::as_str))
            .filter(|value| !value.trim().is_empty());
        let Some(title) = title else { continue; };
        let creator = row.get("user").and_then(|user| user.get("name"))
            .and_then(serde_json::Value::as_str).filter(|value| !value.trim().is_empty())
            .unwrap_or(artist_name);
        albums.push(AudiusCollection {
            id: id.to_string(), title: title.trim().to_string(), creator: creator.to_string(),
            kind: "Album".into(), provider: "audius".into(), external_url: None,
        });
    }
    Ok(albums)
}

fn fetch_audius_artist_profile(artist: &AudiusArtist) -> Result<AudiusArtistProfile, String> {
    if artist.provider != "audius" {
        return Err("This artist profile is hosted by an external music provider".into());
    }
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

    // Load the artist's album catalog separately from individual tracks.
    let mut albums = Vec::new();
    for page in 0..2 {
        let offset = (page * 50).to_string();
        let response = client.get(format!("https://api.audius.co/v1/users/{}/albums", artist.id))
            .query(&[("limit", "50"), ("offset", offset.as_str()), ("sort_method", "recent")])
            .send().and_then(|response| response.error_for_status());
        let response = match response {
            Ok(response) => response,
            Err(error) if page == 0 => return Err(format!("Artist albums request failed: {error}")),
            Err(_) => break,
        };
        let payload: serde_json::Value = match response.json() {
            Ok(payload) => payload,
            Err(error) if page == 0 => return Err(format!("Artist albums response was unreadable: {error}")),
            Err(_) => break,
        };
        let page_albums = parse_audius_artist_albums(&payload, &name)?;
        let page_len = page_albums.len();
        albums.extend(page_albums);
        if page_len < 50 { break; }
    }

    // Load a bounded portion of the artist's public discography, not only
    // the first 50 most-played uploads.
    let mut tracks = Vec::new();
    let mut seen_track_ids = HashSet::new();
    for page in 0..3 {
        let offset = (page * 50).to_string();
        let response = client
            .get(format!("https://api.audius.co/v1/users/{}/tracks", artist.id))
            .query(&[
                ("limit", "50"),
                ("offset", offset.as_str()),
                ("filter_tracks", "public"),
                ("gate_condition", "ungated"),
                ("sort", "date"),
                ("sort_direction", "desc"),
            ])
            .send()
            .and_then(|response| response.error_for_status());
        let response = match response {
            Ok(response) => response,
            Err(error) if page == 0 => return Err(format!("Artist tracks request failed: {error}")),
            Err(_) => break,
        };
        let tracks_payload: serde_json::Value = match response.json() {
            Ok(payload) => payload,
            Err(error) if page == 0 => return Err(format!("Artist tracks response was unreadable: {error}")),
            Err(_) => break,
        };
        let page_tracks = parse_audius_tracks(&tracks_payload)?;
        let page_len = page_tracks.len();
        for track in page_tracks {
            if seen_track_ids.insert(track.id.clone()) {
                tracks.push(track);
            }
        }
        if page_len < 50 { break; }
    }
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
        albums,
        tracks,
    })
}

fn merge_independent_discovery(relevant: Vec<Track>, recent: Vec<Track>) -> Vec<Track> {
    let mut seen = HashSet::new();
    let mut merged = Vec::with_capacity(relevant.len() + recent.len());
    let mut relevant_index = 0;
    let mut recent_index = 0;
    let mut take_relevant = true;

    while relevant_index < relevant.len() || recent_index < recent.len() {
        let source = if take_relevant {
            if relevant_index < relevant.len() {
                let track = &relevant[relevant_index];
                relevant_index += 1;
                Some(track)
            } else if recent_index < recent.len() {
                let track = &recent[recent_index];
                recent_index += 1;
                Some(track)
            } else {
                None
            }
        } else if recent_index < recent.len() {
            let track = &recent[recent_index];
            recent_index += 1;
            Some(track)
        } else if relevant_index < relevant.len() {
            let track = &relevant[relevant_index];
            relevant_index += 1;
            Some(track)
        } else {
            None
        };

        if let Some(track) = source {
            if seen.insert(track.id) {
                merged.push(track.clone());
                take_relevant = !take_relevant;
            }
        }
    }
    merged
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

    // Fetch three bounded pages so broad searches expose more than the first
    // popularity/relevance slice, without creating an unbounded catalog crawl.
    let mut tracks = Vec::new();
    let mut seen_ids = HashSet::new();
    for page in 0..3 {
        let offset = (page * 50).to_string();
        let response = client
            .get("https://api.audius.co/v1/tracks/search")
            .query(&[
                ("query", query),
                ("limit", "50"),
                ("offset", offset.as_str()),
                ("sort_method", normalized_sort_method(sort_method)),
                ("app_name", "RaptorMusic"),
            ])
            .send()
            .and_then(|response| response.error_for_status());
        let response = match response {
            Ok(response) => response,
            Err(error) if page == 0 => return Err(format!("Audius search request failed: {error}")),
            Err(_) => break,
        };
        let payload: serde_json::Value = match response.json() {
            Ok(payload) => payload,
            Err(error) if page == 0 => return Err(format!("Audius returned unreadable search results: {error}")),
            Err(_) => break,
        };
        let page_tracks = parse_audius_tracks(&payload)?;
        let page_len = page_tracks.len();
        for track in page_tracks {
            if seen_ids.insert(track.id.clone()) {
                tracks.push(track);
            }
        }
        if page_len < 50 {
            break;
        }
    }
    Ok(tracks)
}

#[cfg(test)]
mod audius_artist_album_tests {
    use super::*;

    #[test]
    fn parses_and_deduplicates_audius_artist_albums() {
        let payload = serde_json::json!({"data":[
            {"id":"album-1","playlist_name":"First EP","user":{"name":"Indie Artist"}},
            {"id":"album-1","playlist_name":"Duplicate EP","user":{"name":"Indie Artist"}},
            {"id":"album-2","title":"Second Album"},
            {"id":"bad id","title":"Invalid"}
        ]});
        let albums = parse_audius_artist_albums(&payload, "Fallback Artist").unwrap();
        assert_eq!(albums.len(), 2);
        assert_eq!(albums[0].title, "First EP");
        assert_eq!(albums[0].creator, "Indie Artist");
        assert_eq!(albums[0].provider, "audius");
        assert_eq!(albums[1].title, "Second Album");
        assert_eq!(albums[1].creator, "Fallback Artist");
    }

    #[test]
    fn malformed_audius_artist_album_payload_is_not_an_empty_success() {
        assert!(parse_audius_artist_albums(&serde_json::json!({"data":null}), "Artist").is_err());
    }
}

#[cfg(test)]
mod apple_music_collection_search_tests {
    use super::*;

    #[test]
    fn parses_apple_music_albums_and_playlists_as_external_handoffs() {
        let payload = serde_json::json!({"results":{
            "albums":{"data":[{"id":"album123","attributes":{
                "name":"Independent Album","artistName":"Independent Artist",
                "url":"https://music.apple.com/us/album/independent-album/123"
            }}]},
            "playlists":{"data":[{"id":"playlist456","attributes":{
                "name":"Fresh Finds","curatorName":"Apple Music",
                "url":"https://music.apple.com/us/playlist/fresh-finds/456"
            }}]}
        }});
        let rows = parse_apple_music_collections(&payload).expect("valid Apple Music response");
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].kind, "Album");
        assert_eq!(rows[0].provider, "apple_music");
        assert_eq!(rows[1].kind, "Playlist");
        assert!(rows.iter().all(|row| row.external_url.as_deref().unwrap().starts_with("https://music.apple.com/")));
    }

    #[test]
    fn rejects_untrusted_apple_music_collection_urls_and_bad_ids() {
        let payload = serde_json::json!({"results":{
            "albums":{"data":[
                {"id":"valid123","attributes":{"name":"Bad host","artistName":"Artist","url":"https://example.com/album"}},
                {"id":"bad/id","attributes":{"name":"Bad id","artistName":"Artist","url":"https://music.apple.com/us/album/good/123"}}
            ]}
        }});
        assert!(parse_apple_music_collections(&payload).unwrap().is_empty());
    }

    #[test]
    fn apple_music_collection_links_reject_custom_ports_and_credentials() {
        assert!(apple_music_web_url("https://music.apple.com:8443/us/album/test/123").is_none());
        assert!(apple_music_web_url("https://user:pass@music.apple.com/us/album/test/123").is_none());
        assert!(apple_music_web_url("https://music.apple.com/us/album/test/123").is_some());
    }

    #[test]
    fn malformed_apple_music_collection_response_is_not_empty_success() {
        assert!(parse_apple_music_collections(&serde_json::json!({"data":[]})).is_err());
    }
}

#[cfg(test)]
mod apple_music_search_tests {
    use super::*;

    #[test]
    fn parses_only_playable_apple_music_previews() {
        let payload = serde_json::json!({
            "results": { "songs": { "data": [
                { "id": "12345", "attributes": {
                    "name": "Test Track", "artistName": "Independent Artist",
                    "albumName": "Test EP", "durationInMillis": 187000,
                    "previews": [{ "url": "https://audio-ssl.itunes.apple.com/preview.m4a" }]
                }},
                { "id": "67890", "attributes": {
                    "name": "No Preview", "artistName": "Another Artist",
                    "previews": []
                }},
                { "id": "99999", "attributes": {
                    "name": "Unsafe Preview", "artistName": "Bad Host",
                    "previews": [{ "url": "https://example.com/audio.m4a" }]
                }}
            ]}}
        });
        let tracks = parse_apple_music_tracks(&payload).expect("valid Apple Music response");
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].title, "Test Track");
        assert_eq!(tracks[0].artist, "Independent Artist");
        assert_eq!(tracks[0].duration_secs, Some(187));
        assert_eq!(tracks[0].album.as_deref(), Some("Test EP · Apple Music preview"));
        assert!(matches!(&tracks[0].source,
            PlaybackSource::RemoteStream { provider_id, provider_track_id }
                if provider_id == "apple_music_preview"
                    && provider_track_id == "https://audio-ssl.itunes.apple.com/preview.m4a"
        ));
    }

    #[test]
    fn malformed_apple_music_response_is_not_reported_as_empty_success() {
        assert!(parse_apple_music_tracks(&serde_json::json!({"data": []})).is_err());
    }
}

#[cfg(test)]
mod independent_discovery_tests {
    use super::*;

    fn track(id: u128, title: &str) -> Track {
        Track {
            id: Uuid::from_u128(id),
            title: title.into(),
            artist: "Independent artist".into(),
            album: None,
            duration_secs: Some(120),
            source: PlaybackSource::RemoteStream {
                provider_id: "audius".into(),
                provider_track_id: format!("track-{id}"),
            },
        }
    }

    #[test]
    fn independent_discovery_interleaves_and_deduplicates_sources() {
        let relevant = vec![track(1, "Relevant A"), track(2, "Shared"), track(3, "Relevant B")];
        let recent = vec![track(4, "Recent A"), track(2, "Shared"), track(5, "Recent B")];
        let merged = merge_independent_discovery(relevant, recent);
        assert_eq!(merged.iter().map(|item| item.id.as_u128()).collect::<Vec<_>>(),
            vec![1, 4, 2, 5, 3]);
    }
}

#[cfg(test)]
mod audius_collection_search_tests {
    use super::*;

    #[test]
    fn parses_album_and_playlist_results_without_private_items() {
        let payload = serde_json::json!({"data":{
            "albums":[
                {"id":"album_1","playlist_name":"Independent EP","user":{"name":"Small Artist"},"is_private":false},
                {"id":"album_2","playlist_name":"Hidden","is_private":true}
            ],
            "playlists":[
                {"id":"playlist_1","playlist_name":"Deep Cuts","user":{"name":"Curator"},"is_delete":false}
            ]
        }});
        let items = parse_audius_collections(&payload).expect("valid autocomplete payload");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].kind, "Album");
        assert_eq!(items[0].creator, "Small Artist");
        assert_eq!(items[1].kind, "Playlist");
    }

    #[test]
    fn malformed_collection_payload_is_not_an_empty_success() {
        assert!(parse_audius_collections(&serde_json::json!({"oops": []})).is_err());
    }
}

#[cfg(test)]
mod jamendo_search_tests {
    use super::*;

    #[test]
    fn parses_licensed_jamendo_results_as_external_links() {
        let payload = serde_json::json!({
            "results": [{
                "id": "1848357",
                "name": "mañana será tarde",
                "artist_name": "fankel",
                "album_name": "Night EP",
                "duration": 272,
                "license_ccurl": "https://creativecommons.org/licenses/by-nc-nd/3.0/"
            }, {
                "id": "invalid/id",
                "name": "Invalid ID",
                "artist_name": "Unknown",
                "license_ccurl": "https://creativecommons.org/licenses/by/4.0/"
            }, {
                "id": "1848358",
                "name": "Missing license",
                "artist_name": "Unknown"
            }]
        });
        let tracks = parse_jamendo_tracks(&payload).expect("valid Jamendo response");
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].title, "mañana será tarde");
        assert_eq!(tracks[0].artist, "fankel");
        assert_eq!(tracks[0].duration_secs, Some(272));
        assert!(tracks[0].album.as_deref().unwrap().contains("Jamendo"));
        assert_eq!(tracks[0].source, PlaybackSource::RemoteStream {
            provider_id: "jamendo_external".into(),
            provider_track_id: "1848357".into(),
        });
    }

    #[test]
    fn rejects_unexpected_jamendo_payload() {
        assert!(parse_jamendo_tracks(&serde_json::json!({"oops": []})).is_err());
    }
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

fn profile_avatar_cache_path(profile_id: Uuid, extension: &str) -> Result<PathBuf, String> {
    let directory = music_data_dir().map_err(|_| "Could not open the Raptor Music data directory".to_string())?
        .join("avatars");
    std::fs::create_dir_all(&directory)
        .map_err(|_| "Could not create the profile-avatar cache".to_string())?;
    Ok(directory.join(format!("{profile_id}.{extension}")))
}

/// Downloads only public profile artwork from known provider CDNs.
/// Redirects, non-image responses, unexpected hosts and oversized files are rejected.
fn is_approved_profile_artwork_host(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    host == "i.scdn.co"
        || host.ends_with(".scdn.co")
        || host.ends_with(".spotifycdn.com")
        || host.ends_with(".googleusercontent.com")
        || host.ends_with(".ggpht.com")
        // Apple Music artwork is served from Apple's mzstatic CDN.
        || host == "mzstatic.com"
        || host.ends_with(".mzstatic.com")
}

fn cache_profile_avatar(url: &str, profile_id: Uuid) -> Result<(), String> {
    let parsed = url::Url::parse(url)
        .map_err(|_| "Profile artwork URL is invalid".to_string())?;
    if parsed.scheme() != "https" || parsed.port_or_known_default() != Some(443) || !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("Profile artwork must use a public HTTPS URL".into());
    }
    let host = parsed.host_str().unwrap_or_default();
    if !is_approved_profile_artwork_host(host) {
        return Err("Profile artwork host is not an approved provider CDN".into());
    }
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(8))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "Could not create the profile-artwork connection".to_string())?;
    let response = client.get(parsed).send()
        .map_err(|_| "Could not retrieve profile artwork".to_string())?;
    if !response.status().is_success() {
        return Err("The provider did not return profile artwork".into());
    }
    if response.content_length().is_some_and(|length| length > 2 * 1024 * 1024) {
        return Err("Profile artwork exceeds the 2 MiB cache limit".into());
    }
    let content_type = response.headers().get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok()).unwrap_or("")
        .split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    let extension = match content_type.as_str() {
        "image/jpeg" => "jpg",
        "image/png" => "png",
        _ => return Err("Only JPEG and PNG provider artwork is supported".into()),
    };
    let mut limited_response = std::io::Read::take(response, (2 * 1024 * 1024 + 1) as u64);
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut limited_response, &mut bytes)
        .map_err(|_| "Could not read profile artwork".to_string())?;
    if bytes.len() > 2 * 1024 * 1024 {
        return Err("Profile artwork exceeds the 2 MiB cache limit".into());
    }
    let valid_image = if extension == "jpg" {
        bytes.starts_with(&[0xff, 0xd8, 0xff])
    } else {
        bytes.starts_with(b"\x89PNG\r\n\x1a\n")
    };
    if !valid_image {
        return Err("Provider artwork did not match its declared image format".into());
    }
    let destination = profile_avatar_cache_path(profile_id, extension)?;
    let temporary = destination.with_extension(format!("{extension}.{}.tmp", Uuid::new_v4()));
    std::fs::write(&temporary, &bytes)
        .map_err(|_| "Could not cache profile artwork".to_string())?;
    std::fs::rename(&temporary, &destination)
        .map_err(|_| "Could not finalize the profile-artwork cache".to_string())?;
    Ok(())
}

fn load_profile_avatar(profile_id: Uuid) -> slint::Image {
    for extension in ["jpg", "png"] {
        if let Ok(path) = profile_avatar_cache_path(profile_id, extension) {
            if let Ok(image) = slint::Image::load_from_path(&path) {
                return image;
            }
        }
    }
    slint::Image::default()
}

fn refresh_imported_profile_list(ui: &MainWindow, db: &Arc<Mutex<LibraryDatabase>>) {
    let db_lock = db.lock().unwrap();
    let profiles = db_lock.get_imported_profiles().unwrap_or_default();
    let rows = profiles.into_iter().map(|profile| ImportedProfileData {
        id: profile.id.to_string().into(),
        name: profile.display_name.or(profile.username).unwrap_or_else(|| "Imported profile".into()).into(),
        subtitle: format!("{} · imported {}", profile.provider, profile.imported_at).into(),
        avatar: load_profile_avatar(profile.id),
    }).collect::<Vec<_>>();
    ui.set_imported_profile_list(slint::ModelRc::new(slint::VecModel::from(rows)));
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

    #[test]
    fn profile_artwork_host_allowlist_accepts_provider_cdns_without_suffix_spoofing() {
        assert!(is_approved_profile_artwork_host("i.scdn.co"));
        assert!(is_approved_profile_artwork_host("lh3.googleusercontent.com"));
        assert!(is_approved_profile_artwork_host("is1-ssl.mzstatic.com"));
        assert!(is_approved_profile_artwork_host("mzstatic.com"));
        assert!(!is_approved_profile_artwork_host("notmzstatic.com"));
        assert!(!is_approved_profile_artwork_host("mzstatic.com.attacker.invalid"));
        assert!(!is_approved_profile_artwork_host("attacker.invalid"));
    }

    #[test]
    fn discord_presence_templates_replace_track_placeholders() {
        assert_eq!(
            render_presence_template("Listening to {title}", "Night Drive", "Example Artist"),
            "Listening to Night Drive"
        );
        assert_eq!(
            render_presence_template("by {artist} · {title}", "Night Drive", "Example Artist"),
            "by Example Artist · Night Drive"
        );
    }
}

#[cfg(test)]
mod apple_music_library_tests {
    use super::*;

    #[test]
    fn parses_library_and_recent_played_track_resources_without_inventing_timestamps() {
        let row = serde_json::json!({
            "id": "l.song-123",
            "attributes": {
                "name": "Independent Track",
                "artistName": "Small Artist",
                "albumName": "Self Released EP",
                "durationInMillis": 183000
            }
        });
        let track = apple_music_track_from_resource(&row).unwrap();
        assert_eq!(track.source_id.as_deref(), Some("l.song-123"));
        assert_eq!(track.title, "Independent Track");
        assert_eq!(track.artist, "Small Artist");
        let listen = profile_import::ImportedListen {
            track,
            played_at: None,
            ms_played: None,
            play_count: 1,
        };
        assert_eq!(listen.play_count, 1);
        assert!(listen.played_at.is_none());
    }

    #[test]
    fn apple_music_artwork_templates_are_restricted_to_apple_cdn() {
        let valid = serde_json::json!({"artwork":{"url":"https://is5-ssl.mzstatic.com/image/{w}x{h}.jpg"}});
        assert_eq!(apple_music_artwork_url(&valid).as_deref(), Some("https://is5-ssl.mzstatic.com/image/512x512.jpg"));
        let invalid = serde_json::json!({"artwork":{"url":"https://attacker.invalid/{w}x{h}.jpg"}});
        assert!(apple_music_artwork_url(&invalid).is_none());
    }
}

#[cfg(test)]
mod apple_music_artist_link_tests {
    use super::*;

    #[test]
    fn apple_music_artist_links_reject_non_apple_hosts_and_insecure_schemes() {
        assert!(apple_music_web_url("https://music.apple.com/us/artist/example/123").is_some());
        assert!(apple_music_web_url("http://music.apple.com/us/artist/example/123").is_none());
        assert!(apple_music_web_url("https://music.apple.com.attacker.invalid/artist/123").is_none());
        assert!(apple_music_web_url("https://attacker.invalid/music.apple.com/artist/123").is_none());
    }

    #[test]
    fn apple_music_artist_results_are_marked_for_external_handoff() {
        let artist = AudiusArtist {
            id: "123".into(), name: "Independent Artist".into(), handle: "Apple Music".into(),
            provider: "apple_music".into(),
            external_url: apple_music_web_url("https://music.apple.com/us/artist/independent-artist/123"),
        };
        assert_eq!(artist.provider, "apple_music");
        assert!(artist.external_url.is_some());
    }
}
#[cfg(test)]
mod musicbrainz_catalog_tests {
    use super::*;
    #[test]
    fn musicbrainz_links_only_allow_official_artist_and_release_group_pages() {
        let artist = Uuid::new_v4(); let release = Uuid::new_v4();
        assert!(musicbrainz_web_url(&format!("https://musicbrainz.org/artist/{artist}")).is_some());
        assert!(musicbrainz_web_url(&format!("https://musicbrainz.org/release-group/{release}")).is_some());
        assert!(musicbrainz_web_url(&format!("http://musicbrainz.org/artist/{artist}")).is_none());
        assert!(musicbrainz_web_url(&format!("https://musicbrainz.org.attacker.invalid/artist/{artist}")).is_none());
        assert!(musicbrainz_web_url("https://musicbrainz.org/artist/not-a-uuid").is_none());
        assert!(musicbrainz_web_url(&format!("https://user:pass@musicbrainz.org/artist/{artist}")).is_none());
    }
    #[test]
    fn musicbrainz_release_groups_are_metadata_only_collection_rows() {
        let id = Uuid::new_v4().to_string();
        let payload = serde_json::json!({"release-groups":[{"id":id,"title":"Independent EP",
            "primary-type":"EP","first-release-date":"2025-04-12","artist-credit":[{"name":"Small Artist"}]}]});
        let rows = parse_musicbrainz_release_groups(&payload).unwrap();
        assert_eq!(rows.len(),1); assert_eq!(rows[0].title,"Independent EP");
        assert_eq!(rows[0].provider,"musicbrainz"); assert_eq!(rows[0].kind,"EP");
        assert!(rows[0].external_url.is_some());
    }

    #[test]
    fn musicbrainz_discography_pages_merge_and_deduplicate_release_groups() {
        let first = Uuid::new_v4().to_string();
        let second = Uuid::new_v4().to_string();
        let pages = vec![
            serde_json::json!({"release-group-count": 201, "release-groups":[
                {"id":first,"title":"First","primary-type":"Album"}
            ]}),
            serde_json::json!({"release-group-count": 201, "release-groups":[
                {"id":first,"title":"First duplicate","primary-type":"Album"},
                {"id":second,"title":"Second","primary-type":"EP"}
            ]})
        ];
        let merged = merge_musicbrainz_release_group_pages(pages).unwrap();
        let rows = merged.get("release-groups").unwrap().as_array().unwrap();
        assert_eq!(merged.get("release-group-count").unwrap().as_u64(), Some(201));
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].get("id").unwrap().as_str(), Some(first.as_str()));
        assert_eq!(rows[1].get("id").unwrap().as_str(), Some(second.as_str()));
    }

    #[test]
    fn musicbrainz_discography_pages_reject_malformed_page_shapes() {
        assert!(merge_musicbrainz_release_group_pages(vec![
            serde_json::json!({"release-groups": []}),
            serde_json::json!({"unexpected": []})
        ]).is_err());
    }

    #[test]
    fn musicbrainz_discography_is_sorted_newest_first() {
        let older = Uuid::new_v4().to_string();
        let newer = Uuid::new_v4().to_string();
        let payload = serde_json::json!({"release-groups":[
            {"id":older,"title":"Older release","primary-type":"Album","first-release-date":"2020"},
            {"id":newer,"title":"Newer release","primary-type":"Single","first-release-date":"2025"}
        ]});
        let rows = parse_musicbrainz_release_groups(&payload).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "Newer release");
        assert_eq!(rows[1].title, "Older release");
    }
}

#[cfg(test)]
mod apple_music_catalog_pagination_tests {
    use super::*;

    #[test]
    fn apple_music_artist_catalog_pagination_stays_on_the_same_artist_endpoint() {
        let base = "https://api.music.apple.com/v1/catalog/us/artists/12345/albums";
        assert!(apple_music_catalog_pagination_url(base, "/v1/catalog/us/artists/12345/albums?offset=25", "us", "12345").is_ok());
        assert!(apple_music_catalog_pagination_url(base, "https://attacker.invalid/v1/catalog/us/artists/12345/albums", "us", "12345").is_err());
        assert!(apple_music_catalog_pagination_url(base, "https://api.music.apple.com:8443/v1/catalog/us/artists/12345/albums", "us", "12345").is_err());
        assert!(apple_music_catalog_pagination_url(base, "/v1/catalog/us/artists/99999/albums?offset=25", "us", "12345").is_err());
        assert!(apple_music_catalog_pagination_url(base, "/v1/me/library/albums?offset=25", "us", "12345").is_err());
        assert!(apple_music_catalog_pagination_url(base, "https://user:pass@api.music.apple.com/v1/catalog/us/artists/12345/albums", "us", "12345").is_err());
    }
}

#[cfg(test)]
mod apple_music_pagination_tests {
    use super::*;

    #[test]
    fn apple_music_pagination_only_accepts_https_api_paths_without_credentials_or_custom_ports() {
        let base = reqwest::Url::parse("https://api.music.apple.com/v1/me/library/songs").unwrap();
        assert!(apple_music_pagination_url(&base, "/v1/me/library/songs?offset=100").is_ok());
        assert!(apple_music_pagination_url(&base, "https://api.music.apple.com:8443/v1/me/library/songs").is_err());
        assert!(apple_music_pagination_url(&base, "https://user:pass@api.music.apple.com/v1/me/library/songs").is_err());
        assert!(apple_music_pagination_url(&base, "https://attacker.invalid/v1/me/library/songs").is_err());
        assert!(apple_music_pagination_url(&base, "http://api.music.apple.com/v1/me/library/songs").is_err());
        assert!(apple_music_pagination_url(&base, "https://api.music.apple.com/v1/catalog/us/songs").is_err());
    }
}

