# Raptor Music

Raptor Music is a desktop music player built with Rust, SQLite, Symphonia/CPAL and Slint. It combines local-file playback with online discovery while keeping the two collections separate in the interface. Its interface is designed around familiar music-app workflows while retaining a distinct Raptor visual identity.

## Desktop experience

- A persistent navigation and library sidebar.
- A searchable track collection matching title, artist and album metadata.
- Playlist creation, selection, track assignment and queue loading.
- A dedicated upcoming-queue panel with selection and removal.
- Persistent now-playing controls, progress display, seek, previous/next and stop.
- A folder picker that scans supported local audio formats and imports metadata into the local SQLite library.
- Debounced online search across public Audius tracks and artist profiles; artist results open the artist's public Audius profile.
- Online discovery remains a separate section from the local collection, with independent artist and track results.
- Queue and playback support for public Audius tracks that the provider marks streamable and not access-gated.

The interface uses familiar music-player navigation and search patterns without copying Spotify's branding or artwork.

## Catalog and privacy boundary

The local library remains fully usable offline. When a search has at least two characters, Raptor Music sends the query to Audius and displays matching public, streamable tracks and artist profiles in a separate online-discovery section. Selecting an online track stores its provider metadata so it can be queued and played through Audius' stream endpoint. Provider-backed tracks are excluded from the Local Library view and are not treated as local files. Stream data is buffered in a temporary per-user runtime file and removed when playback ends.

Audius is the only online catalog currently integrated. It is not a mirror of Spotify's catalog, and its available artists and tracks differ substantially. Album and playlist search, genre browsing, recommendations, pagination, and additional catalog providers remain future work. Online search and playback require network access. The provider receives the search query and normal connection metadata; local file names, playlists, and listening history are not uploaded by Raptor Music.

Raptor Music itself has no ads, subscription requirement, app telemetry, or always-on background server. Existing local files remain under the user's control.

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
