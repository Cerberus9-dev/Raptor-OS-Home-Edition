# Raptor Music

Raptor Music is a desktop player built with Rust, SQLite, Symphonia/CPAL and Slint. It handles music already on the computer and online discovery, but keeps those collections separate so local files do not get mixed up with provider results.


### Independent-artist discovery

Discover includes an **Independent** sort option that blends Audius relevance-ranked matches with recent uploads and interleaves the two lists while deduplicating tracks. This is intended to give newer and less-played artists a fairer chance to appear without replacing normal relevance, popularity, or recency sorting. Results still depend on what the connected catalog indexes; this does not imply every artist or release is available.

### Albums and playlists

Discover now queries Audius autocomplete for album and playlist matches alongside artist and track search. Album and playlist rows are shown separately from tracks; selecting one loads its track list into the online results so tracks can be selected and played with the existing player controls. The catalog only returns public, available items that the provider exposes. This is catalog discovery, not a connected Audius user account.

### Music-service account connections

The provider sign-in roadmap uses each service's supported authorization method rather than collecting service passwords. TIDAL and Spotify require their own registered OAuth applications and approved use; Apple Music uses MusicKit developer and Music User Tokens; Google OAuth can authorize YouTube Data API access to a user's YouTube playlists, but it is not a YouTube Music playback/catalog API. These account connections are not yet shipped. No client secrets, private keys, or tokens are bundled in the repository. A linked account does not automatically grant Raptor Music permission to stream that service's catalog.

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

Raptor Music currently searches Audius and can also search the Apple Music catalog when a developer token is configured. Audius provides artist discovery and public, streamable tracks. Apple Music contributes catalog matches with short preview clips where Apple supplies a preview URL; those clips are not full-song subscription playback. Apple Music preview files are restricted to Apple's preview hosts, buffered temporarily, and removed when playback ends.

This is an early multi-catalog foundation, not Spotify-sized coverage yet. Album and playlist search, pagination, genre and label discovery, and more artist sources are still important next steps. Popularity should not be the only ranking signal: exact artist matches, smaller artists and newer releases need room to surface.

The goal is a large, searchable catalog without pretending every provider grants the same rights. Each result must retain its source, artwork attribution and playback rules. Catalogs that only provide metadata must not be presented as playable, and providers that prohibit combining their content with other services must remain in their own clearly separated area. Open catalogs and providers that permit independent clients are the best route to wider discovery, especially for independent and underground artists.

Online searches send the query to the enabled catalog providers, along with normal connection metadata. Local file names, local playlists and listening history are not uploaded. Local Library searches remain offline-only.

Raptor Music has no ads, subscription requirement, app telemetry or always-running background server.

## Connected music accounts

Direct sign-in is not implemented yet. Raptor Music now has browser-based account connection controls for Spotify and Google/YouTube Data API. TIDAL connection is intentionally disabled pending written developer approval. Sign-in uses provider authorization and PKCE rather than collecting service passwords. The callback listener binds only to the configured loopback IP, validates OAuth state and redirect path, and has bounded request and timeout handling. OAuth credentials are stored in the operating system credential manager (Secret Service on Linux, Windows Credential Manager, or Apple Keychain), not in the music database. Each provider has a disconnect control that removes its saved credentials.

Provider support is not interchangeable:

- **Spotify:** Spotify documents OAuth Authorization Code with PKCE for desktop apps. Its developer rules prohibit integrating Spotify content with streams or content from another service and restrict apps that replace Spotify's core experience without written permission. That means a Spotify login cannot simply turn Raptor Music into a combined Spotify-and-Audius streaming client. A narrowly scoped, user-directed playlist-data transfer is a separate use case and still needs to follow Spotify's current rules.
- **Apple Music:** Catalog song search and short preview playback are implemented when `RAPTOR_APPLE_MUSIC_DEVELOPER_TOKEN` is supplied. The optional `RAPTOR_APPLE_MUSIC_STOREFRONT` setting selects a two-letter storefront (defaults to `us`). This is catalog access, not account sign-in. MusicKit user authorization, personal-library access and full subscription playback are not implemented yet. A developer token must be generated by the app developer; never put the MusicKit private key in the desktop app or repository.
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

The first provider-connection foundation now generates PKCE verifier/challenge pairs, prepares official authorization URLs for Spotify, TIDAL and Google/YouTube Data API, validates callback state, and includes an authorization-code token-exchange primitive. Client IDs and exact registered redirect URIs are supplied through environment configuration; TIDAL scopes can be configured separately. No provider credentials are embedded in the repository. This is not a finished sign-in flow yet: callback parsing with state validation and a refresh-token exchange primitive are now included. Spotify account identity and playlist metadata retrieval are now wired to the documented Web API, and Google/YouTube Data API can retrieve the connected channel and its YouTube playlist metadata. The YouTube results are not described as YouTube Music playlists or playback access. TIDAL profile/playlist retrieval remains disabled until its exact API endpoints and permissions are verified. A loopback-only callback receiver and OS credential-manager persistence primitives are now present, alongside bounded pagination for Spotify and YouTube Data API playlist metadata. They are not yet wired into the Settings UI or a complete sign-in/import lifecycle. Disconnect/revocation, playlist-track retrieval, account profile persistence, Apple Music MusicKit user authorization, verified TIDAL profile/playlist access, and runtime provider-account testing remain outstanding. Apple Music requires its separate MusicKit user-authorization path rather than this generic OAuth flow. Spotify desktop authorization uses Authorization Code with PKCE and must not be used to combine Spotify streams with other providers. Google OAuth authorizes YouTube Data API access, not a YouTube Music catalog/playback API. TIDAL access and any combined-catalog behavior require review against its current developer terms and written approval where required.

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
