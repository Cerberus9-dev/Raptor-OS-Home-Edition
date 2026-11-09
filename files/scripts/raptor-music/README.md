# Raptor Music

Raptor Music is a desktop player built with Rust, SQLite, Symphonia/CPAL and Slint. It handles music already on the computer and online discovery, but keeps those collections separate so local files do not get mixed up with provider results.

## Using the app

- **Discover** is the starting point for online track and artist search.
- **Local Library** searches music imported from folders on the computer. It works offline and does not send search terms to the online catalog.
- Artist results open in Raptor Music, with profile details and playable popular tracks where the provider makes them available.
- Tracks from the online catalog can be added to the queue and played when they are public, streamable and not access-gated.
- Click a track to start it immediately. The player keeps the current queue moving, and the dock has one-tap previous/next track and 15-second rewind/skip controls.
- Use the three-dot song menu to add a track to the queue or any playlist. The queue and playlists stay editable while music is playing.
- Playback runs on its own audio worker, so it continues while the window is minimized or you're using another app. Closing Raptor Music ends playback for now.
- Playlists, the upcoming queue and the playback dock have their own controls. Queue actions respond to the current selection.
- Folder import scans supported audio formats and stores track metadata in the local SQLite library.
- Search can sort by relevance, popularity or recency. A query can return up to 50 tracks and 30 artists.

## Online catalog and privacy

Audius is currently the only online catalog connected to Raptor Music. Its catalog is not the same size or coverage as Spotify's, and some artists or tracks will not be available. Album and playlist search, genre browsing, recommendations, pagination and additional catalog providers are not implemented yet.

Online searches send the query to Audius, along with normal connection metadata. Local file names, local playlists and listening history are not uploaded. Online playback uses a temporary file in the user's cache and removes it when playback ends.

Raptor Music has no ads, subscription requirement, app telemetry or always-running background server.

## Importing a music profile

The import flow is for supported account-data exports, not password-based account access. Choose the JSON export files, review the profile information and collections Raptor Music can read, then confirm the import. The app can save the imported profile so it can be opened again later from **Imported Profiles**.

The current importer understands Raptor Music profile packages and supported Spotify JSON exports. Depending on what the source files contain, an import can include:

- Profile details and avatar artwork.
- Playlists, including their order and available track information.
- Saved tracks and followed artists.
- Listening events and history supplied by the export.

Multiple files can be selected together. Imports can be merged and deduplicated, and profiles without a stable account username are kept as separate imports. The Imported Profiles view lets users browse the saved profile's playlists, saved tracks, followed artists and listening history.

There are limits. Export formats differ, and a provider may leave out profile photos, follows, albums or listening history. Raptor Music only imports information actually present in supported files; it does not fill in missing account data by guessing. It does not sign in to external services, scrape private endpoints or bypass provider controls. Importing a track entry does not download its audio or guarantee it can be played. Imported collections remain separate from the Local Library and from listening activity recorded in Raptor Music.

Direct account connections, OAuth-based imports, automatic refresh, and support for more export formats are future work. Any future connection will need clear permissions, secure token storage and a way to revoke access.

## Discord Rich Presence

Open **Settings** and enter the Client ID for your Discord application. Rich Presence works with Discord desktop and compatible clients that expose the local Discord RPC socket, including clients such as Vesktop and Equibop. Raptor Music does not need a Raptor-hosted account or server for this.

Turn Rich Presence on, then edit the details and state templates. Use `{title}` and `{artist}` to insert the current track information. Playback and pause state are reflected in the status. Rich Presence is off by default; users choose whether to enable it and which text to share. The feature requires a compatible client to be running on the same desktop session.

## Workspace

- `raptor-core`: shared track models and playback events
- `raptor-library`: SQLite library, playlists, queue and persisted state
- `raptor-audio`: decoding, resampling, channel conversion and playback worker
- `raptor-desktop`: Slint desktop application

Build and test the workspace with:

```sh
cargo build --workspace
cargo test --workspace
```

## Raptor OS image

The image workflow builds and tests the workspace, stages the desktop app, and checks that the executable, launcher, desktop entry and icon are present in the finished Raptor OS image.
