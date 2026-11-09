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
- Search checks tracks and artists together, accepts song titles, artist names and general keywords, and sorts by relevance, popularity or recency. Short queries are not blocked by a two-character minimum; results can include up to 50 tracks and 30 artists per request.

## Online catalog and privacy

Audius is currently the only online catalog connected to Raptor Music. Its coverage is not comparable to Spotify's, and some artists or tracks will not be available yet. The next catalog work is broader provider coverage, album and playlist search, pagination, genre and label discovery, and artist-first results. Popularity should not be the only ranking signal: exact artist matches, smaller artists and newer releases need room to surface.

The goal is a large, searchable catalog without pretending every provider grants the same rights. Each result must retain its source, artwork attribution and playback rules. Catalogs that only provide metadata must not be presented as playable, and providers that prohibit combining their content with other services must remain in their own clearly separated area. Open catalogs and providers that permit independent clients are the best route to wider discovery, especially for independent and underground artists.

Online searches currently send the query to Audius, along with normal connection metadata. Local file names, local playlists and listening history are not uploaded. Online playback uses a temporary file in the user's cache and removes it when playback ends.

Raptor Music has no ads, subscription requirement, app telemetry or always-running background server.

## Connected music accounts

Direct sign-in is not implemented yet. The intended experience is an official provider sign-in and permission screen—not a Raptor Music form asking users for another service's password. Account linking must use the provider's supported authorization flow, request only the permissions needed, store credentials in the operating system's secure credential store, and include a clear disconnect option.

Provider support is not interchangeable:

- **Spotify:** Spotify documents OAuth Authorization Code with PKCE for desktop apps. Its developer rules prohibit integrating Spotify content with streams or content from another service and restrict apps that replace Spotify's core experience without written permission. That means a Spotify login cannot simply turn Raptor Music into a combined Spotify-and-Audius streaming client. A narrowly scoped, user-directed playlist-data transfer is a separate use case and still needs to follow Spotify's current rules.
- **Apple Music:** MusicKit and the Apple Music API support catalog search, artist and album information, and—after user authorization—personal library features. Playback and account access need to use Apple's supported MusicKit path and developer credentials.
- **YouTube Music:** Google provides the YouTube Data API and OAuth for YouTube account data, but that is not an official YouTube Music catalog-and-playback API. A Google sign-in alone must not be advertised as YouTube Music integration.
- **TIDAL:** TIDAL documents OAuth 2.1 with PKCE. Its developer terms restrict competing offerings and combining TIDAL content with content from other services, so a multi-provider player needs TIDAL's written approval before integrating its catalog or playback.

Until each provider's access and terms are confirmed, Raptor Music will not scrape private endpoints, collect provider passwords, or claim that linking an account grants streaming rights.

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

Turn Rich Presence on, then choose a personal phrase such as “Jamming out to”. Raptor Music adds the current track title automatically and fills the artist line from the playing track. The track and artist templates can still use `{title}` and `{artist}` for further customization. Playback and pause state are reflected in the status. Rich Presence is off by default; users choose whether to enable it and which text to share. The feature requires a compatible client to be running on the same desktop session.

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
