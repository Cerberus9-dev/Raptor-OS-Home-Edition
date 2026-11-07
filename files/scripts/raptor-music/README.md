# Raptor Music

Raptor Music is a local-first desktop music library and player built with Rust, SQLite, Symphonia/CPAL and Slint. Its interface is designed around familiar music-app workflows while retaining a distinct Raptor visual identity.

## Desktop experience

- A persistent navigation and library sidebar.
- A searchable track collection matching title, artist and album metadata.
- Playlist creation, selection, track assignment and queue loading.
- A dedicated upcoming-queue panel with selection and removal.
- Persistent now-playing controls, progress display, seek, previous/next and stop.
- A folder picker that scans supported local audio formats and imports metadata into the local SQLite library.

The interface is Spotify-inspired in its information architecture and ease of browsing, not a copy of Spotify's branding or artwork.

## Current service boundary

The current catalog is the user's imported local music. It does not yet provide a hosted global streaming catalog or online discovery feed. Streaming providers require supported APIs, authentication and rights-compatible playback; Raptor Music must not pretend it can search or play those catalogs until each integration is implemented and tested.

Raptor Music remains local-first: no ads, subscription requirement, tracking, or always-on background server. Existing local files remain under the user's control.

## Workspace

- `raptor-core`: shared track models, playback events and capabilities
- `raptor-library`: SQLite library, playlists, queue and persisted state
- `raptor-audio`: decoding, resampling, channel conversion and playback worker
- `raptor-desktop`: Slint desktop application

```sh
cargo build --workspace
cargo test --workspace
```

## Image integration

CI builds and tests the workspace on every image build, stages the desktop executable, and verifies the launcher, desktop entry and icon inside the published Raptor OS image.
