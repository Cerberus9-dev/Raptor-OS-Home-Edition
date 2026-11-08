# Raptor Music

Raptor Music is a local-first desktop music library and player built with Rust, SQLite, Symphonia/CPAL and Slint. Its interface is designed around familiar music-app workflows while retaining a distinct Raptor visual identity.

## Desktop experience

- A persistent navigation and library sidebar.
- A searchable track collection matching title, artist and album metadata.
- Playlist creation, selection, track assignment and queue loading.
- A dedicated upcoming-queue panel with selection and removal.
- Persistent now-playing controls, progress display, seek, previous/next and stop.
- A folder picker that scans supported local audio formats and imports metadata into the local SQLite library.
- Debounced online search across songs and artists in the public Audius catalog, shown separately from the local library.
- Queue and playback support for public Audius tracks that the provider marks streamable and not access-gated.

The interface uses familiar music-player navigation and search patterns without copying Spotify's branding or artwork.

## Catalog and privacy boundary

The local library remains fully usable offline. When a search has at least two characters, Raptor Music also sends that query to Audius and displays matching public, streamable tracks in a separate Discover section. Selecting an online result saves its track metadata and provider ID to the local library; adding it to the queue enables playback through Audius' official stream endpoint. Stream data is buffered in a temporary per-user runtime file and removed when playback ends.

Audius is an additional discovery catalog, not a mirror of Spotify's complete catalog. Availability depends on the artists and tracks published there, and online search/playback requires network access. The provider receives the search query and normal connection metadata; local file names, playlists, and listening history are not uploaded by Raptor Music.

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
