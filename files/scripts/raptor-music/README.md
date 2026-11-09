# Raptor Music

Raptor Music is a desktop music player built with Rust, SQLite, Symphonia/CPAL and Slint. It combines local-file playback with online discovery while keeping the two collections separate in the interface. Its interface is designed around familiar music-app workflows while retaining a distinct Raptor visual identity.

## Desktop experience

- Separate **Discover** and **Local Library** views, with online discovery as the default landing view.
- A searchable local collection matching title, artist and album metadata; local browsing stays offline and never sends queries to the online catalog.
- Online discovery and local files never appear in the same results list.
- Playlist creation, selection, track assignment and queue loading.
- A dedicated upcoming-queue panel with selection and removal.
- Persistent now-playing controls, progress display, seek, previous/next and stop.
- A folder picker that scans supported local audio formats and imports metadata into the local SQLite library.
- Debounced online search across public tracks and artist profiles, with in-app artist pages showing profile details and playable popular tracks.
- Search sorting by relevance, popularity, or recency, with up to 50 track results and 30 artist results per query.
- Online artist and track results live only in Discover; switching to Local Library clears online results and prevents unnecessary catalog requests.
- Context-aware empty states for a library with no imported files and a queue with no upcoming tracks.
- Playback controls reflect player state and disable queue actions when there is no valid selection.
- Queue and playback support for public Audius tracks that the provider marks streamable and not access-gated.

The interface uses familiar music-player navigation and search patterns without copying Spotify's branding or artwork.

## Catalog and privacy boundary

The local library remains fully usable offline. Discover is the default view. When a search has at least two characters while Discover is active, Raptor Music sends the query to the online catalog and displays matching public, streamable tracks and artist profiles. Searching in Local Library never makes a catalog request. Selecting an online artist opens an in-app profile with its biography, public track/follower counts, and up to 50 playable popular tracks. Selecting an online track stores its provider metadata so it can be queued and played. Provider-backed tracks are excluded from the Local Library view and are not treated as local files. Stream data is buffered in a temporary per-user runtime file and removed when playback ends.

Audius is the only online catalog currently integrated. It is not a mirror of Spotify's catalog, and its available artists and tracks differ substantially. Album and playlist search, genre browsing, recommendations, pagination, and additional catalog providers remain future work. Search sorting currently changes the provider's relevance, popularity, or recency ordering; it does not make Audius' catalog equivalent in size or coverage to Spotify. Online search and playback require network access. The provider receives the search query and normal connection metadata; local file names, playlists, and listening history are not uploaded by Raptor Music.

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

## Full profile migration (planned)

Raptor Music's import experience is intended to migrate a music profile, not merely copy a list of playlist URLs. The target experience is a guided **Import profile** flow: choose a source service, connect through its official authorization flow or select an official account-data export, preview what is available, then import the profile into Raptor Music.

Where the source service and its terms permit it, a migration can include:

- Profile identity: display name, username, biography, and profile image.
- Collections: created playlists, saved/liked tracks, saved albums, and followed artists.
- Activity: recently played tracks and listening history, including play timestamps and counts when supplied by the source.
- Playlist details: title, description, ordering, track entries, and artwork when available.

Imported information should appear together on a Raptor Music profile page, with sections for playlists, saved music, followed artists, and listening activity. The original service should be recorded as the import source, and users should be able to refresh supported imports, unlink a connected account, or remove imported data. Imported history must remain distinguishable from listening activity recorded natively by Raptor Music.

Import should be a transparent migration, not a promise that every source item can be played. Raptor should match imported tracks against playable catalog entries where permitted, preserve unmatched entries as unavailable migration records, report partial imports, and avoid silently dropping songs. Duplicate detection should use stable provider identifiers when available and conservative metadata matching otherwise. Re-importing or refreshing must not duplicate playlists, tracks, or history.

Each service needs a capability-aware adapter because profile photos, playlists, likes, follows, albums, and listening history are not uniformly exposed. Use official APIs with narrowly scoped authorization or user-provided exports; never scrape private endpoints, request account passwords, or bypass provider controls. Respect provider licensing, attribution, branding, and display requirements even where that means a particular service cannot offer a fully unified profile import. Do not claim a field was imported when the source did not supply it.

The migration should provide a preview before writing data, explain unavailable categories, preserve the user's existing Raptor library, and keep imported collections separable from collections created in Raptor. OAuth tokens, if a future adapter needs them, must be stored securely and be revocable; they must never be written to logs or the music database in plaintext.

This is a product roadmap item, not a currently shipped feature. Current Raptor Music supports local-folder import and Audius online discovery; it does not yet connect external music accounts or import full profiles.
