//! OAuth and metadata-import helpers for supported music providers.
//! Authorization does not grant streaming rights; credentials stay out of source control.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use sha2::{Digest, Sha256};
use uuid::Uuid;
use url::Url;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OAuthProvider {
    Spotify,
    Tidal,
    YoutubeData,
}

#[derive(Clone, Debug)]
pub struct PendingAuthorization {
    pub provider: OAuthProvider,
    pub state: String,
    pub code_verifier: String,
    pub redirect_uri: String,
    pub client_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AuthorizationError {
    MissingClientId(&'static str),
    MissingRedirectUri(&'static str),
    InvalidRedirectUri,
    InvalidCallbackState,
}

impl std::fmt::Display for AuthorizationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingClientId(name) => write!(f, "Set {name} in the app environment"),
            Self::MissingRedirectUri(name) => write!(f, "Set {name} to the redirect URI registered with the provider"),
            Self::InvalidRedirectUri => write!(f, "The configured redirect URI is invalid"),
            Self::InvalidCallbackState => write!(f, "The authorization response state did not match the request"),
        }
    }
}

impl std::error::Error for AuthorizationError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CallbackError {
    ProviderRejected(String),
    MissingCode,
    MissingState,
    InvalidState,
}

impl std::fmt::Display for CallbackError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ProviderRejected(reason) => write!(f, "Provider authorization was declined: {reason}"),
            Self::MissingCode => write!(f, "The provider callback did not include an authorization code"),
            Self::MissingState => write!(f, "The provider callback did not include its security state"),
            Self::InvalidState => write!(f, "The provider callback did not match the pending sign-in request"),
        }
    }
}

impl std::error::Error for CallbackError {}

/// Extracts an authorization code only when the callback contains the exact
/// state generated for this pending authorization request.
pub fn parse_authorization_callback(
    callback_url: &str,
    pending: &PendingAuthorization,
) -> Result<String, CallbackError> {
    let callback = Url::parse(callback_url)
        .map_err(|_| CallbackError::MissingCode)?;
    let expected_redirect = Url::parse(&pending.redirect_uri)
        .map_err(|_| CallbackError::MissingCode)?;
    if callback.origin() != expected_redirect.origin()
        || callback.path() != expected_redirect.path()
        || callback.username() != ""
        || callback.password().is_some()
    {
        return Err(CallbackError::InvalidState);
    }
    let mut code = None;
    let mut state = None;
    let mut provider_error = None;
    for (key, value) in callback.query_pairs() {
        match key.as_ref() {
            "code" => code = Some(value.into_owned()),
            "state" => state = Some(value.into_owned()),
            "error" | "error_description" => {
                provider_error.get_or_insert(value.into_owned());
            }
            _ => {}
        }
    }
    if let Some(reason) = provider_error {
        return Err(CallbackError::ProviderRejected(reason));
    }
    let actual_state = state.ok_or(CallbackError::MissingState)?;
    validate_callback_state(&pending.state, &actual_state)
        .map_err(|_| CallbackError::InvalidState)?;
    code.filter(|value| !value.trim().is_empty()).ok_or(CallbackError::MissingCode)
}

impl OAuthProvider {
    fn settings(self) -> (&'static str, &'static str, &'static str, &'static str, &'static str) {
        match self {
            Self::Spotify => (
                "RAPTOR_SPOTIFY_CLIENT_ID",
                "RAPTOR_SPOTIFY_REDIRECT_URI",
                "https://accounts.spotify.com/authorize",
                "https://accounts.spotify.com/api/token",
                "user-read-private playlist-read-private playlist-read-collaborative user-library-read user-follow-read user-read-recently-played",
            ),
            Self::Tidal => (
                "RAPTOR_TIDAL_CLIENT_ID",
                "RAPTOR_TIDAL_REDIRECT_URI",
                "https://login.tidal.com/authorize",
                "https://auth.tidal.com/v1/oauth2/token",
                "user.read playlists.read",
            ),
            Self::YoutubeData => (
                "RAPTOR_GOOGLE_CLIENT_ID",
                "RAPTOR_GOOGLE_REDIRECT_URI",
                "https://accounts.google.com/o/oauth2/v2/auth",
                "https://oauth2.googleapis.com/token",
                "openid email profile https://www.googleapis.com/auth/youtube.readonly",
            ),
        }
    }
}

/// Creates a high-entropy PKCE verifier from three UUIDv4 values (96 hex
/// characters), then derives the S256 challenge required by native OAuth apps.
pub fn create_pkce_pair() -> (String, String) {
    let verifier = format!("{}{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let digest = Sha256::digest(verifier.as_bytes());
    let challenge = URL_SAFE_NO_PAD.encode(digest);
    (verifier, challenge)
}

/// Prepares the provider's official authorization URL. The app must register
/// the exact redirect URI with that provider before this can be used.
pub fn begin_authorization(
    provider: OAuthProvider,
    redirect_override: Option<&str>,
) -> Result<(Url, PendingAuthorization), AuthorizationError> {
    let (client_env, redirect_env, endpoint, _token_endpoint, default_scopes) = provider.settings();
    let client_id = std::env::var(client_env)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or(AuthorizationError::MissingClientId(client_env))?;
    let redirect_uri = redirect_override
        .map(str::to_owned)
        .or_else(|| std::env::var(redirect_env).ok())
        .filter(|value| !value.trim().is_empty())
        .ok_or(AuthorizationError::MissingRedirectUri(redirect_env))?;
    let redirect = Url::parse(&redirect_uri).map_err(|_| AuthorizationError::InvalidRedirectUri)?;
    if redirect.scheme() != "http" && redirect.scheme() != "https" {
        return Err(AuthorizationError::InvalidRedirectUri);
    }

    let scopes = if provider == OAuthProvider::Tidal {
        std::env::var("RAPTOR_TIDAL_SCOPES").unwrap_or_else(|_| default_scopes.to_string())
    } else {
        default_scopes.to_string()
    };
    let (code_verifier, code_challenge) = create_pkce_pair();
    let state = Uuid::new_v4().simple().to_string();
    let mut url = Url::parse(endpoint).expect("provider authorization endpoint is a valid URL");
    {
        let mut query = url.query_pairs_mut();
        query.append_pair("response_type", "code");
        query.append_pair("client_id", &client_id);
        query.append_pair("redirect_uri", &redirect_uri);
        query.append_pair("state", &state);
        query.append_pair("code_challenge_method", "S256");
        query.append_pair("code_challenge", &code_challenge);
        if !scopes.is_empty() {
            query.append_pair("scope", &scopes);
        }
        if provider == OAuthProvider::YoutubeData {
            query.append_pair("access_type", "offline");
            query.append_pair("prompt", "consent");
        }
    }

    Ok((url, PendingAuthorization {
        provider,
        state,
        code_verifier,
        redirect_uri,
        client_id,
    }))
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct OAuthTokenResponse {
    pub access_token: String,
    pub token_type: String,
    pub expires_in: u64,
    pub refresh_token: Option<String>,
    pub scope: Option<String>,
    pub id_token: Option<String>,
}

/// Exchanges a provider authorization code using the original PKCE verifier.
/// The caller must validate callback state before calling this function and
/// store returned credentials only in the operating system's secure store.
pub fn exchange_authorization_code(
    pending: &PendingAuthorization,
    authorization_code: &str,
) -> Result<OAuthTokenResponse, String> {
    if authorization_code.trim().is_empty() {
        return Err("The provider returned an empty authorization code".into());
    }
    let (_, _, _, token_endpoint, _) = pending.provider.settings();
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|error| format!("Could not create provider connection: {error}"))?;
    let response = client.post(token_endpoint)
        .form(&[
            ("grant_type", "authorization_code"),
            ("client_id", pending.client_id.as_str()),
            ("code", authorization_code),
            ("redirect_uri", pending.redirect_uri.as_str()),
            ("code_verifier", pending.code_verifier.as_str()),
        ])
        .send()
        .map_err(|error| format!("Provider token exchange failed: {error}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("Provider token exchange returned HTTP {status}"));
    }
    response.json::<OAuthTokenResponse>()
        .map_err(|error| format!("Provider returned an unreadable token response: {error}"))
}


/// Refreshes a provider grant without exposing refresh tokens to the UI.
/// Returned credentials must be persisted only in the operating system's
/// secure credential store by the caller.
pub fn refresh_access_token(
    pending: &PendingAuthorization,
    refresh_token: &str,
) -> Result<OAuthTokenResponse, String> {
    if refresh_token.trim().is_empty() {
        return Err("No refresh token is available for this provider account".into());
    }
    let (_, _, _, token_endpoint, _) = pending.provider.settings();
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|error| format!("Could not create provider connection: {error}"))?;
    let response = client.post(token_endpoint)
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", pending.client_id.as_str()),
            ("refresh_token", refresh_token),
        ])
        .send()
        .map_err(|error| format!("Provider token refresh failed: {error}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("Provider token refresh returned HTTP {status}"));
    }
    response.json::<OAuthTokenResponse>()
        .map_err(|error| format!("Provider returned an unreadable refreshed token response: {error}"))
}


#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ProviderProfile {
    pub provider: String,
    pub id: String,
    pub display_name: String,
    pub avatar_url: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ProviderPlaylist {
    pub provider: String,
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub image_url: Option<String>,
    pub item_count: Option<u64>,
}

fn first_image_url(value: &serde_json::Value) -> Option<String> {
    value.as_array()?.first()?.get("url")?.as_str().map(str::to_owned)
}

fn parse_spotify_profile(value: &serde_json::Value) -> Result<ProviderProfile, String> {
    let id = value.get("id").and_then(|v| v.as_str()).filter(|v| !v.is_empty())
        .ok_or_else(|| "Spotify profile did not include an account ID".to_string())?;
    Ok(ProviderProfile {
        provider: "spotify".into(),
        id: id.into(),
        display_name: value.get("display_name").and_then(|v| v.as_str()).unwrap_or(id).into(),
        avatar_url: first_image_url(&value["images"]),
    })
}

fn parse_spotify_playlists(value: &serde_json::Value) -> Result<Vec<ProviderPlaylist>, String> {
    let items = value.get("items").and_then(|v| v.as_array())
        .ok_or_else(|| "Spotify playlist response did not include an items list".to_string())?;
    Ok(items.iter().filter_map(|item| {
        let id = item.get("id")?.as_str()?;
        let name = item.get("name")?.as_str()?;
        Some(ProviderPlaylist {
            provider: "spotify".into(),
            id: id.into(),
            name: name.into(),
            description: item.get("description").and_then(|v| v.as_str()).filter(|v| !v.is_empty()).map(str::to_owned),
            image_url: first_image_url(&item["images"]),
            item_count: item.pointer("/items/total").and_then(|v| v.as_u64())
                .or_else(|| item.pointer("/tracks/total").and_then(|v| v.as_u64())),
        })
    }).collect())
}

fn parse_youtube_playlists(value: &serde_json::Value) -> Result<Vec<ProviderPlaylist>, String> {
    let items = value.get("items").and_then(|v| v.as_array())
        .ok_or_else(|| "YouTube playlist response did not include an items list".to_string())?;
    Ok(items.iter().filter_map(|item| {
        let id = item.get("id")?.as_str()?;
        let snippet = item.get("snippet")?;
        let name = snippet.get("title")?.as_str()?;
        let thumbnails = snippet.get("thumbnails")?;
        let image_url = ["maxres", "standard", "high", "medium", "default"]
            .iter()
            .find_map(|key| thumbnails.get(*key)?.get("url")?.as_str().map(str::to_owned));
        Some(ProviderPlaylist {
            provider: "youtube".into(),
            id: id.into(),
            name: name.into(),
            description: snippet.get("description").and_then(|v| v.as_str()).filter(|v| !v.is_empty()).map(str::to_owned),
            image_url,
            item_count: item.pointer("/contentDetails/itemCount").and_then(|v| v.as_u64()),
        })
    }).collect())
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ProviderPlaylistTrack {
    pub provider: String,
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_secs: Option<u64>,
    pub artwork_url: Option<String>,
    pub external_url: Option<String>,
}

fn parse_spotify_playlist_tracks(value: &serde_json::Value) -> Result<Vec<ProviderPlaylistTrack>, String> {
    let items = value.get("items").and_then(|v| v.as_array())
        .ok_or_else(|| "Spotify playlist-track response did not include an items list".to_string())?;
    Ok(items.iter().filter_map(|item| {
        let track = item.get("item").or_else(|| item.get("track"))?;
        let id = track.get("id")?.as_str()?;
        let title = track.get("name")?.as_str()?;
        let artists = track.get("artists").and_then(|v| v.as_array())
            .map(|values| values.iter().filter_map(|artist| artist.get("name").and_then(|v| v.as_str())).collect::<Vec<_>>().join(", "))
            .filter(|value| !value.is_empty()).unwrap_or_else(|| "Unknown artist".into());
        let album = track.pointer("/album/name").and_then(|v| v.as_str()).map(str::to_owned);
        let artwork_url = track.get("album").and_then(|v| first_image_url(&v["images"]));
        let external_url = track.pointer("/external_urls/spotify").and_then(|v| v.as_str()).map(str::to_owned);
        let duration_secs = track.get("duration_ms").and_then(|v| v.as_u64()).map(|ms| ms / 1000);
        Some(ProviderPlaylistTrack {
            provider: "spotify".into(), id: id.into(), title: title.into(),
            artist: artists, album, duration_secs, artwork_url, external_url,
        })
    }).collect())
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ProviderFollowedArtist {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ProviderListen {
    pub track: ProviderPlaylistTrack,
    pub played_at: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct SpotifyProfileExtras {
    pub saved_tracks: Vec<ProviderPlaylistTrack>,
    pub followed_artists: Vec<ProviderFollowedArtist>,
    pub listening_history: Vec<ProviderListen>,
    /// Optional sections that could not be read with the account's current API access.
    pub warnings: Vec<String>,
}

fn parse_youtube_playlist_tracks(value: &serde_json::Value) -> Result<Vec<ProviderPlaylistTrack>, String> {
    let items = value.get("items").and_then(|v| v.as_array())
        .ok_or_else(|| "YouTube playlist-item response did not include an items list".to_string())?;
    Ok(items.iter().filter_map(|item| {
        let snippet = item.get("snippet")?;
        let id = snippet.pointer("/resourceId/videoId")?.as_str()?;
        let title = snippet.get("title")?.as_str()?;
        if title == "Private video" || title == "Deleted video" { return None; }
        let artist = snippet.get("videoOwnerChannelTitle")
            .or_else(|| snippet.get("channelTitle"))
            .and_then(|v| v.as_str()).unwrap_or("Unknown channel");
        let thumbnails = snippet.get("thumbnails")?;
        let artwork_url = ["maxres", "standard", "high", "medium", "default"]
            .iter().find_map(|key| thumbnails.get(*key)?.get("url")?.as_str().map(str::to_owned));
        Some(ProviderPlaylistTrack {
            provider: "youtube".into(), id: id.into(), title: title.into(),
            artist: artist.into(), album: None, duration_secs: None, artwork_url,
            external_url: Some(format!("https://www.youtube.com/watch?v={id}")),
        })
    }).collect())
}

fn tidal_user_id_from_access_token(access_token: &str) -> Result<String, String> {
    let payload = access_token.split('.').nth(1)
        .ok_or_else(|| "TIDAL returned a token without a readable user identity claim".to_string())?;
    let bytes = URL_SAFE_NO_PAD.decode(payload)
        .map_err(|_| "TIDAL access token did not contain a valid JWT payload".to_string())?;
    let claims: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|_| "TIDAL access token payload was not valid JSON".to_string())?;
    claims.get("sub").and_then(|value| value.as_str())
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "TIDAL access token did not include a user subject".to_string())
}

fn get_tidal_json(url: &str, access_token: &str) -> Result<serde_json::Value, String> {
    let parsed = Url::parse(url).map_err(|_| "TIDAL API returned an invalid URL".to_string())?;
    if parsed.scheme() != "https" || parsed.host_str() != Some("openapi.tidal.com") {
        return Err("TIDAL pagination returned an untrusted API host; import stopped.".into());
    }
    let response = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|error| format!("Could not create TIDAL connection: {error}"))?
        .get(parsed)
        .header(reqwest::header::ACCEPT, "application/vnd.api+json")
        .bearer_auth(access_token)
        .send()
        .map_err(|error| format!("TIDAL API request failed: {error}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("TIDAL API returned HTTP {status}; check the app's granted scopes and access tier"));
    }
    response.json::<serde_json::Value>()
        .map_err(|error| format!("TIDAL returned unreadable account data: {error}"))
}

fn parse_tidal_profile(value: &serde_json::Value, user_id: &str) -> Result<ProviderProfile, String> {
    let data = value.get("data").ok_or_else(|| "TIDAL user response did not include resource data".to_string())?;
    let id = data.get("id").and_then(|value| value.as_str()).unwrap_or(user_id);
    let attributes = data.get("attributes").cloned().unwrap_or_default();
    let display_name = ["displayName", "username", "name"]
        .iter()
        .find_map(|key| attributes.get(*key).and_then(|value| value.as_str()))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(id);
    Ok(ProviderProfile {
        provider: "tidal".into(),
        id: id.into(),
        display_name: display_name.into(),
        avatar_url: attributes.get("picture").and_then(|value| value.as_str()).map(str::to_owned),
    })
}

fn parse_tidal_playlists(value: &serde_json::Value) -> Result<Vec<ProviderPlaylist>, String> {
    let data = value.get("data").and_then(|value| value.as_array())
        .ok_or_else(|| "TIDAL playlist response did not include a data list".to_string())?;
    Ok(data.iter().filter_map(|item| {
        let id = item.get("id")?.as_str()?;
        let attributes = item.get("attributes")?;
        let name = attributes.get("name").or_else(|| attributes.get("title"))?.as_str()?;
        Some(ProviderPlaylist {
            provider: "tidal".into(),
            id: id.into(),
            name: name.into(),
            description: attributes.get("description").and_then(|value| value.as_str())
                .filter(|value| !value.is_empty()).map(str::to_owned),
            image_url: attributes.get("imageUrl").and_then(|value| value.as_str()).map(str::to_owned),
            item_count: attributes.get("numberOfItems").and_then(|value| value.as_u64())
                .or_else(|| item.pointer("/relationships/items/meta/total").and_then(|value| value.as_u64())),
        })
    }).collect())
}

fn fetch_tidal_profile(access_token: &str) -> Result<ProviderProfile, String> {
    let user_id = tidal_user_id_from_access_token(access_token)?;
    let mut url = Url::parse("https://openapi.tidal.com/v2/users")
        .expect("TIDAL user endpoint is a valid URL");
    url.path_segments_mut().map_err(|_| "Could not construct TIDAL user URL".to_string())?
        .push(&user_id);
    let value = get_tidal_json(url.as_str(), access_token)?;
    parse_tidal_profile(&value, &user_id)
}

fn fetch_tidal_playlist_pages(access_token: &str) -> Result<Vec<ProviderPlaylist>, String> {
    let user_id = tidal_user_id_from_access_token(access_token)?;
    let mut url = Url::parse("https://openapi.tidal.com/v2/playlists")
        .expect("TIDAL playlist endpoint is a valid URL");
    url.query_pairs_mut()
        .append_pair("filter[owners.id]", &user_id)
        .append_pair("page[limit]", "50")
        .append_pair("include", "coverArt,ownerProfiles");
    let mut playlists = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for _ in 0..100 {
        let value = get_tidal_json(url.as_str(), access_token)?;
        playlists.extend(parse_tidal_playlists(&value)?);
        match value.pointer("/links/next").and_then(|value| value.as_str()).filter(|value| !value.is_empty()) {
            Some(next) if seen.insert(next.to_owned()) => {
                url = Url::parse(next).map_err(|_| "TIDAL returned an invalid playlist page link".to_string())?;
            }
            Some(_) => return Err("TIDAL returned a repeated playlist page link; import stopped safely.".into()),
            None => return Ok(playlists),
        }
    }
    Err("TIDAL playlist import reached the 5,000-item safety limit.".into())
}

fn get_provider_json(url: &str, access_token: &str) -> Result<serde_json::Value, String> {
    if access_token.trim().is_empty() {
        return Err("The provider access token is empty".into());
    }
    let response = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(20))
        .build()
        .map_err(|error| format!("Could not create provider connection: {error}"))?
        .get(url)
        .bearer_auth(access_token)
        .send()
        .map_err(|error| format!("Provider API request failed: {error}"))?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("Provider API returned HTTP {status}"));
    }
    response.json::<serde_json::Value>()
        .map_err(|error| format!("Provider returned unreadable account data: {error}"))
}

/// Retrieves basic account identity from providers with documented user APIs.

pub fn fetch_provider_profile(provider: OAuthProvider, access_token: &str) -> Result<ProviderProfile, String> {
    match provider {
        OAuthProvider::Spotify => parse_spotify_profile(&get_provider_json("https://api.spotify.com/v1/me", access_token)?),
        OAuthProvider::YoutubeData => {
            let value = get_provider_json("https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true", access_token)?;
            let channel = value.get("items").and_then(|v| v.as_array()).and_then(|v| v.first())
                .ok_or_else(|| "No YouTube channel was returned for this Google account".to_string())?;
            let snippet = &channel["snippet"];
            let id = channel.get("id").and_then(|v| v.as_str())
                .ok_or_else(|| "YouTube channel response did not include an ID".to_string())?;
            Ok(ProviderProfile {
                provider: "youtube".into(),
                id: id.into(),
                display_name: snippet.get("title").and_then(|v| v.as_str()).unwrap_or(id).into(),
                avatar_url: snippet.pointer("/thumbnails/default/url").and_then(|v| v.as_str()).map(str::to_owned),
            })
        }
        OAuthProvider::Tidal => fetch_tidal_profile(access_token),
    }
}

/// Retrieves every page of a provider's playlist metadata. Pagination is
/// bounded and repeated page tokens are rejected so a malformed provider
/// response cannot trap the desktop app in an endless import.
fn fetch_spotify_playlist_pages(access_token: &str) -> Result<Vec<ProviderPlaylist>, String> {
    let mut playlists = Vec::new();
    let mut offset = 0usize;
    for _ in 0..200 {
        let url = format!("https://api.spotify.com/v1/me/playlists?limit=50&offset={offset}");
        let value = get_provider_json(&url, access_token)?;
        let page = parse_spotify_playlists(&value)?;
        let page_len = page.len();
        playlists.extend(page);
        let has_next = value.get("next").and_then(|v| v.as_str()).is_some();
        if !has_next || page_len == 0 {
            return Ok(playlists);
        }
        offset = offset.saturating_add(50);
    }
    Err("Spotify playlist import reached the 10,000-item safety limit; retry to continue.".into())
}

fn fetch_youtube_playlist_pages(access_token: &str) -> Result<Vec<ProviderPlaylist>, String> {
    let mut playlists = Vec::new();
    let mut page_token: Option<String> = None;
    let mut seen_tokens = std::collections::HashSet::new();
    for _ in 0..200 {
        let mut url = Url::parse("https://www.googleapis.com/youtube/v3/playlists")
            .expect("YouTube playlist endpoint is a valid URL");
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("part", "snippet,contentDetails");
            query.append_pair("mine", "true");
            query.append_pair("maxResults", "50");
            if let Some(token) = page_token.as_deref() {
                query.append_pair("pageToken", token);
            }
        }
        let value = get_provider_json(url.as_str(), access_token)?;
        playlists.extend(parse_youtube_playlists(&value)?);
        match value.get("nextPageToken").and_then(|v| v.as_str()).filter(|v| !v.is_empty()) {
            Some(next) if seen_tokens.insert(next.to_owned()) => page_token = Some(next.to_owned()),
            Some(_) => return Err("YouTube returned a repeated playlist page token; import stopped safely.".into()),
            None => return Ok(playlists),
        }
    }
    Err("YouTube playlist import reached the 10,000-item safety limit; retry to continue.".into())
}

/// Imports all available playlist metadata from Spotify or a Google account's
/// YouTube channel. YouTube Data API playlists are not YouTube Music catalog
/// access. Provider API permissions and account visibility still apply.
pub fn fetch_provider_playlists(provider: OAuthProvider, access_token: &str) -> Result<Vec<ProviderPlaylist>, String> {
    match provider {
        OAuthProvider::Spotify => fetch_spotify_playlist_pages(access_token),
        OAuthProvider::YoutubeData => fetch_youtube_playlist_pages(access_token),
        OAuthProvider::Tidal => fetch_tidal_playlist_pages(access_token),
    }
}

fn fetch_spotify_saved_tracks(access_token: &str) -> Result<Vec<ProviderPlaylistTrack>, String> {
    let mut tracks = Vec::new();
    for page in 0..200usize {
        let mut url = Url::parse("https://api.spotify.com/v1/me/tracks")
            .expect("Spotify saved-tracks endpoint is valid");
        url.query_pairs_mut().append_pair("limit", "50")
            .append_pair("offset", &(page * 50).to_string());
        let value = get_provider_json(url.as_str(), access_token)?;
        let batch = parse_spotify_playlist_tracks(&value)?;
        let count = batch.len();
        tracks.extend(batch);
        if value.get("next").and_then(|v| v.as_str()).is_none() || count == 0 {
            return Ok(tracks);
        }
    }
    Err("Spotify saved-track import reached the 10,000-item safety limit.".into())
}

fn fetch_spotify_followed_artists(access_token: &str) -> Result<Vec<ProviderFollowedArtist>, String> {
    let mut artists = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen_cursors = std::collections::HashSet::new();
    for _ in 0..200 {
        let mut url = Url::parse("https://api.spotify.com/v1/me/following")
            .expect("Spotify following endpoint is valid");
        {
            let mut query = url.query_pairs_mut();
            query.append_pair("type", "artist");
            query.append_pair("limit", "50");
            if let Some(after) = cursor.as_deref() { query.append_pair("after", after); }
        }
        let value = get_provider_json(url.as_str(), access_token)?;
        let items = value.pointer("/artists/items").and_then(|v| v.as_array())
            .ok_or_else(|| "Spotify followed-artist response did not include an items list".to_string())?;
        artists.extend(items.iter().filter_map(|item| Some(ProviderFollowedArtist {
            id: item.get("id")?.as_str()?.to_owned(),
            name: item.get("name")?.as_str()?.to_owned(),
        })));
        let next = value.pointer("/artists/cursors/after").and_then(|v| v.as_str());
        let has_next = value.pointer("/artists/next").and_then(|v| v.as_str()).is_some();
        if !has_next || next.is_none() { return Ok(artists); }
        let next = next.unwrap().to_owned();
        if !seen_cursors.insert(next.clone()) {
            return Err("Spotify returned a repeated followed-artist cursor; import stopped safely.".into());
        }
        cursor = Some(next);
    }
    Err("Spotify followed-artist import reached the 10,000-item safety limit.".into())
}

fn spotify_recently_played_url(before: Option<&str>) -> Url {
    let mut url = Url::parse("https://api.spotify.com/v1/me/player/recently-played")
        .expect("Spotify recent-history endpoint is valid");
    {
        let mut query = url.query_pairs_mut();
        query.append_pair("limit", "50");
        // The first page is newest. Follow the backward cursor to avoid
        // requesting events newer than the first page.
        if let Some(cursor) = before { query.append_pair("before", cursor); }
    }
    url
}

fn fetch_spotify_recently_played(access_token: &str) -> Result<Vec<ProviderListen>, String> {
    let mut listens = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen_cursors = std::collections::HashSet::new();
    for _ in 0..200 {
        let url = spotify_recently_played_url(cursor.as_deref());
        let value = get_provider_json(url.as_str(), access_token)?;
        let items = value.get("items").and_then(|v| v.as_array())
            .ok_or_else(|| "Spotify listening-history response did not include an items list".to_string())?;
        for item in items {
            let track_value = serde_json::json!({"items": [{"track": item.get("track").cloned().unwrap_or(serde_json::Value::Null)}]});
            if let Some(track) = parse_spotify_playlist_tracks(&track_value)?.into_iter().next() {
                listens.push(ProviderListen {
                    track,
                    played_at: item.get("played_at").and_then(|v| v.as_str()).map(str::to_owned),
                });
            }
        }
        let next = value.pointer("/cursors/before").and_then(|v| v.as_str());
        let has_next = value.get("next").and_then(|v| v.as_str()).is_some();
        if !has_next || next.is_none() { return Ok(listens); }
        let next = next.unwrap().to_owned();
        if !seen_cursors.insert(next.clone()) {
            return Err("Spotify returned a repeated listening-history cursor; import stopped safely.".into());
        }
        cursor = Some(next);
    }
    Err("Spotify listening-history import reached the 10,000-item safety limit.".into())
}

/// Retrieves each optional Spotify profile collection independently.
/// A permission or endpoint failure must not discard collections that were
/// already available to the user. Errors are summarized for the UI.
pub fn fetch_spotify_profile_extras(access_token: &str) -> SpotifyProfileExtras {
    let mut warnings = Vec::new();
    let saved_tracks = collect_optional_provider_section(
        "Saved tracks", fetch_spotify_saved_tracks(access_token), &mut warnings,
    );
    let followed_artists = collect_optional_provider_section(
        "Followed artists", fetch_spotify_followed_artists(access_token), &mut warnings,
    );
    let listening_history = collect_optional_provider_section(
        "Listening history", fetch_spotify_recently_played(access_token), &mut warnings,
    );
    SpotifyProfileExtras { saved_tracks, followed_artists, listening_history, warnings }
}

pub fn collect_optional_provider_section<T>(
    label: &str,
    result: Result<Vec<T>, String>,
    warnings: &mut Vec<String>,
) -> Vec<T> {
    match result {
        Ok(items) => items,
        Err(error) => {
            warnings.push(format!("{label} unavailable: {error}"));
            Vec::new()
        }
    }
}

/// Imports every page of playlist entries from supported metadata APIs.
/// Spotify entries are metadata only; YouTube entries are video references,
/// not playable YouTube Music tracks.
pub fn fetch_provider_playlist_tracks(
    provider: OAuthProvider,
    access_token: &str,
    playlist_id: &str,
) -> Result<Vec<ProviderPlaylistTrack>, String> {
    if playlist_id.trim().is_empty() {
        return Err("A playlist ID is required".into());
    }
    match provider {
        OAuthProvider::Spotify => {
            let mut tracks = Vec::new();
            for page in 0..200usize {
                let mut url = Url::parse("https://api.spotify.com/v1/")
                    .expect("Spotify API base URL is valid");
                {
                    let mut segments = url.path_segments_mut()
                        .map_err(|_| "Could not construct Spotify playlist URL".to_string())?;
                    segments.pop_if_empty().push("playlists").push(playlist_id).push("items");
                }
                url.query_pairs_mut().append_pair("limit", "50")
                    .append_pair("offset", &(page * 50).to_string());
                let value = get_provider_json(url.as_str(), access_token)?;
                let batch = parse_spotify_playlist_tracks(&value)?;
                let count = batch.len();
                tracks.extend(batch);
                if value.get("next").and_then(|v| v.as_str()).is_none() || count == 0 {
                    return Ok(tracks);
                }
            }
            Err("Spotify playlist import reached the 20,000-track safety limit.".into())
        }
        OAuthProvider::YoutubeData => {
            let mut tracks = Vec::new();
            let mut page_token: Option<String> = None;
            let mut seen_tokens = std::collections::HashSet::new();
            for _ in 0..200 {
                let mut url = Url::parse("https://www.googleapis.com/youtube/v3/playlistItems")
                    .expect("YouTube playlist-item endpoint is valid");
                {
                    let mut query = url.query_pairs_mut();
                    query.append_pair("part", "snippet,contentDetails");
                    query.append_pair("playlistId", playlist_id);
                    query.append_pair("maxResults", "50");
                    if let Some(token) = page_token.as_deref() {
                        query.append_pair("pageToken", token);
                    }
                }
                let value = get_provider_json(url.as_str(), access_token)?;
                tracks.extend(parse_youtube_playlist_tracks(&value)?);
                match value.get("nextPageToken").and_then(|v| v.as_str()).filter(|v| !v.is_empty()) {
                    Some(next) if seen_tokens.insert(next.to_owned()) => page_token = Some(next.to_owned()),
                    Some(_) => return Err("YouTube returned a repeated playlist-item page token; import stopped safely.".into()),
                    None => return Ok(tracks),
                }
            }
            Err("YouTube playlist import reached the 10,000-item safety limit.".into())
        }
        OAuthProvider::Tidal => Err("TIDAL playlist item metadata import is not implemented yet; the linked account and playlist metadata remain available.".into()),
    }
}

/// Rejects callbacks that do not echo the unguessable request state.
pub fn validate_callback_state(expected: &str, actual: &str) -> Result<(), AuthorizationError> {
    let expected = expected.as_bytes();
    let actual = actual.as_bytes();
    let mut difference = expected.len() ^ actual.len();
    let max_len = expected.len().max(actual.len());
    for index in 0..max_len {
        let left = expected.get(index).copied().unwrap_or(0);
        let right = actual.get(index).copied().unwrap_or(0);
        difference |= (left ^ right) as usize;
    }
    if difference == 0 && !expected.is_empty() {
        Ok(())
    } else {
        Err(AuthorizationError::InvalidCallbackState)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pkce_verifier_and_challenge_have_native_app_shape() {
        let (verifier, challenge) = create_pkce_pair();
        assert!((43..=128).contains(&verifier.len()));
        assert_eq!(verifier.len(), 96);
        assert_eq!(challenge.len(), 43);
        assert!(verifier.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert!(challenge.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'));
    }

    #[test]
    fn callback_state_must_match_exactly() {
        assert!(validate_callback_state("expected-state", "expected-state").is_ok());
        assert_eq!(validate_callback_state("expected-state", "attacker-state"), Err(AuthorizationError::InvalidCallbackState));
        assert_eq!(validate_callback_state("", ""), Err(AuthorizationError::InvalidCallbackState));
    }

    #[test]
    fn spotify_authorization_url_uses_pkce_and_registered_redirect() {
        std::env::set_var("RAPTOR_SPOTIFY_CLIENT_ID", "test-client");
        let (url, pending) = begin_authorization(
            OAuthProvider::Spotify,
            Some("http://127.0.0.1:43821/callback"),
        ).expect("authorization request");
        let query = url.query_pairs().into_owned().collect::<std::collections::HashMap<_, _>>();
        assert_eq!(query.get("client_id").map(String::as_str), Some("test-client"));
        assert_eq!(query.get("redirect_uri").map(String::as_str), Some("http://127.0.0.1:43821/callback"));
        assert_eq!(query.get("code_challenge_method").map(String::as_str), Some("S256"));
        assert_eq!(query.get("state"), Some(&pending.state));
        assert_eq!(pending.provider, OAuthProvider::Spotify);
        std::env::remove_var("RAPTOR_SPOTIFY_CLIENT_ID");
    }


    #[test]
    fn spotify_profile_and_playlist_metadata_are_normalized() {
        let profile = parse_spotify_profile(&serde_json::json!({
            "id": "artist-fan", "display_name": "Listener",
            "images": [{"url": "https://example.test/avatar.jpg"}]
        })).unwrap();
        assert_eq!(profile.id, "artist-fan");
        assert_eq!(profile.display_name, "Listener");
        assert_eq!(profile.avatar_url.as_deref(), Some("https://example.test/avatar.jpg"));

        let playlists = parse_spotify_playlists(&serde_json::json!({
            "items": [{
                "id": "mix-1", "name": "My Mix", "description": "Saved songs",
                "images": [{"url": "https://example.test/cover.jpg"}],
                "items": {"total": 42}
            }]
        })).unwrap();
        assert_eq!(playlists.len(), 1);
        assert_eq!(playlists[0].item_count, Some(42));
        assert_eq!(playlists[0].name, "My Mix");
    }

    #[test]
    fn tidal_jwt_subject_and_json_api_resources_are_normalized() {
        let payload = URL_SAFE_NO_PAD.encode(br#"{"sub":"tidal-user-42"}"#);
        let token = format!("header.{payload}.signature");
        assert_eq!(tidal_user_id_from_access_token(&token).unwrap(), "tidal-user-42");

        let profile = parse_tidal_profile(&serde_json::json!({
            "data": {
                "id": "tidal-user-42",
                "type": "users",
                "attributes": {"username": "independent_listener"}
            }
        }), "fallback-user").unwrap();
        assert_eq!(profile.provider, "tidal");
        assert_eq!(profile.id, "tidal-user-42");
        assert_eq!(profile.display_name, "independent_listener");

        let playlists = parse_tidal_playlists(&serde_json::json!({
            "data": [{
                "id": "playlist-1",
                "type": "playlists",
                "attributes": {
                    "name": "Night Drive",
                    "description": "Independent discoveries",
                    "numberOfItems": 37
                }
            }]
        })).unwrap();
        assert_eq!(playlists.len(), 1);
        assert_eq!(playlists[0].provider, "tidal");
        assert_eq!(playlists[0].name, "Night Drive");
        assert_eq!(playlists[0].item_count, Some(37));
    }

    #[test]
    fn youtube_playlist_metadata_is_not_mislabeled_as_music_catalog() {
        let playlists = parse_youtube_playlists(&serde_json::json!({
            "items": [{
                "id": "yt-list-1",
                "snippet": {
                    "title": "Favorites", "description": "Saved videos",
                    "thumbnails": {"default": {"url": "https://example.test/thumb.jpg"}}
                },
                "contentDetails": {"itemCount": 12}
            }]
        })).unwrap();
        assert_eq!(playlists[0].provider, "youtube");
        assert_eq!(playlists[0].item_count, Some(12));
    }

    #[test]
    fn callback_parser_requires_matching_state_before_returning_code() {
        let pending = PendingAuthorization {
            provider: OAuthProvider::Spotify,
            state: "expected-state".into(),
            code_verifier: "verifier".into(),
            redirect_uri: "http://127.0.0.1/callback".into(),
            client_id: "client".into(),
        };
        let callback = "http://127.0.0.1/callback?code=auth-code&state=expected-state";
        assert_eq!(parse_authorization_callback(callback, &pending).unwrap(), "auth-code");
        assert_eq!(
            parse_authorization_callback("http://127.0.0.1/callback?code=auth-code&state=wrong", &pending),
            Err(CallbackError::InvalidState)
        );
        assert_eq!(
            parse_authorization_callback("http://evil.test/callback?code=auth-code&state=expected-state", &pending),
            Err(CallbackError::InvalidState)
        );
        assert_eq!(
            parse_authorization_callback("http://127.0.0.1/callback?error=access_denied&state=expected-state", &pending),
            Err(CallbackError::ProviderRejected("access_denied".into()))
        );
    }

    #[test]
    fn callback_parser_rejects_missing_code_or_state() {
        let pending = PendingAuthorization {
            provider: OAuthProvider::Spotify,
            state: "expected-state".into(),
            code_verifier: "verifier".into(),
            redirect_uri: "http://127.0.0.1/callback".into(),
            client_id: "client".into(),
        };
        assert_eq!(
            parse_authorization_callback("http://127.0.0.1/callback?state=expected-state", &pending),
            Err(CallbackError::MissingCode)
        );
        assert_eq!(
            parse_authorization_callback("http://127.0.0.1/callback?code=auth-code", &pending),
            Err(CallbackError::MissingState)
        );
    }

    #[test]
    fn optional_provider_collection_failure_does_not_discard_other_collections() {
        let mut warnings = Vec::new();
        let saved = collect_optional_provider_section(
            "Saved tracks", Ok(vec!["saved-a", "saved-b"]), &mut warnings,
        );
        let followed: Vec<&str> = collect_optional_provider_section(
            "Followed artists", Err("HTTP 403".into()), &mut warnings,
        );
        let history = collect_optional_provider_section(
            "Listening history", Ok(vec!["recent-song"]), &mut warnings,
        );

        assert_eq!(saved, vec!["saved-a", "saved-b"]);
        assert!(followed.is_empty());
        assert_eq!(history, vec!["recent-song"]);
        assert_eq!(warnings, vec!["Followed artists unavailable: HTTP 403"]);
    }

    #[test]
    fn token_response_parser_keeps_refresh_and_identity_tokens_optional() {
        let response: OAuthTokenResponse = serde_json::from_str(
            r#"{"access_token":"access","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh","scope":"read","id_token":"identity"}"#
        ).expect("valid token response");
        assert_eq!(response.access_token, "access");
        assert_eq!(response.refresh_token.as_deref(), Some("refresh"));
        assert_eq!(response.id_token.as_deref(), Some("identity"));
    }

    #[test]
    fn playlist_pagination_safety_contracts_are_present() {
        let source = include_str!("provider_auth.rs");
        assert!(source.contains("fetch_spotify_playlist_pages"));
        assert!(source.contains("fetch_youtube_playlist_pages"));
        assert!(source.contains("repeated playlist page token"));
        assert!(source.contains("10,000-item safety limit"));
    }

    #[test]
    fn spotify_recent_history_uses_backward_cursor_for_older_pages() {
        let first_page = spotify_recently_played_url(None);
        let first_query = first_page.query_pairs().into_owned().collect::<std::collections::HashMap<_, _>>();
        assert_eq!(first_query.get("limit").map(String::as_str), Some("50"));
        assert!(!first_query.contains_key("after"));
        assert!(!first_query.contains_key("before"));

        let next_page = spotify_recently_played_url(Some("1730462400000"));
        let query = next_page.query_pairs().into_owned().collect::<std::collections::HashMap<_, _>>();
        assert_eq!(query.get("before").map(String::as_str), Some("1730462400000"));
        assert!(!query.contains_key("after"));
    }

    #[test]
    fn spotify_profile_extras_normalize_followed_artists_and_history() {
        let followed = serde_json::json!({
            "artists": {
                "items": [{"id": "artist-1", "name": "Independent Artist"}],
                "next": null,
                "cursors": {"after": null}
            }
        });
        let items = followed.pointer("/artists/items").and_then(|v| v.as_array()).unwrap();
        assert_eq!(items[0]["name"], "Independent Artist");

        let history = serde_json::json!({
            "items": [{
                "track": {
                    "id": "track-2", "name": "Recent Song",
                    "artists": [{"name": "Band"}],
                    "album": {"name": "Record", "images": []},
                    "duration_ms": 120000
                },
                "played_at": "2026-11-01T12:00:00Z"
            }],
            "cursors": {"after": null},
            "next": null
        });
        let row = &history["items"][0];
        let wrapped = serde_json::json!({"items": [{"item": row["track"]}]});
        let track = parse_spotify_playlist_tracks(&wrapped).unwrap().remove(0);
        assert_eq!(track.title, "Recent Song");
        assert_eq!(row["played_at"], "2026-11-01T12:00:00Z");
    }

    #[test]
    fn spotify_playlist_track_metadata_is_normalized_without_stream_urls() {
        let tracks = parse_spotify_playlist_tracks(&serde_json::json!({
            "items": [{
                "item": {
                    "id": "track-1", "name": "Underground Song",
                    "artists": [{"name": "Small Artist"}, {"name": "Guest"}],
                    "album": {"name": "Independent EP", "images": [{"url": "https://example.test/cover.jpg"}]},
                    "duration_ms": 187500,
                    "external_urls": {"spotify": "https://open.spotify.com/track/track-1"}
                }
            }]
        })).unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].artist, "Small Artist, Guest");
        assert_eq!(tracks[0].duration_secs, Some(187));
        assert_eq!(tracks[0].provider, "spotify");
        assert_eq!(tracks[0].external_url.as_deref(), Some("https://open.spotify.com/track/track-1"));
    }

    #[test]
    fn youtube_playlist_items_are_video_references_not_music_streams() {
        let tracks = parse_youtube_playlist_tracks(&serde_json::json!({
            "items": [{
                "snippet": {
                    "title": "Uploaded live session",
                    "channelTitle": "Independent Channel",
                    "resourceId": {"videoId": "video-123"},
                    "thumbnails": {"default": {"url": "https://example.test/thumb.jpg"}}
                }
            }]
        })).unwrap();
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].provider, "youtube");
        assert_eq!(tracks[0].artist, "Independent Channel");
        assert_eq!(tracks[0].external_url.as_deref(), Some("https://www.youtube.com/watch?v=video-123"));
        assert_eq!(tracks[0].duration_secs, None);
    }

    #[test]
    fn youtube_data_is_explicitly_a_separate_google_oauth_provider() {
        let settings = OAuthProvider::YoutubeData.settings();
        assert_eq!(settings.0, "RAPTOR_GOOGLE_CLIENT_ID");
        assert!(settings.4.contains("youtube.readonly"));
        assert_eq!(settings.3, "https://oauth2.googleapis.com/token");
    }
}
