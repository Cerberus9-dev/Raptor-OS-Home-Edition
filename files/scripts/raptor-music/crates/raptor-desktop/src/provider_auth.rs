//! Provider-native authorization primitives for Raptor Music.
//!
//! This module only prepares authorization requests. It does not claim that a
//! successful login grants streaming rights, and it deliberately keeps provider
//! credentials out of source control. Token exchange is implemented as a
//! separate primitive; callback listening, OS-keyring persistence and provider-
//! specific profile/playlist adapters remain separate steps.

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
                "user-read-private user-read-email playlist-read-private playlist-read-collaborative user-library-read user-follow-read",
            ),
            Self::Tidal => (
                "RAPTOR_TIDAL_CLIENT_ID",
                "RAPTOR_TIDAL_REDIRECT_URI",
                "https://login.tidal.com/authorize",
                "https://auth.tidal.com/v1/oauth2/token",
                "",
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
        std::env::var("RAPTOR_TIDAL_SCOPES").unwrap_or_default()
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

#[derive(Clone, Debug, serde::Deserialize)]
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
            item_count: item.pointer("/tracks/total").and_then(|v| v.as_u64()),
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
/// TIDAL's account endpoint is intentionally not guessed; it needs its own
/// verified adapter before being enabled here.
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
        OAuthProvider::Tidal => Err("TIDAL profile retrieval needs its verified API adapter; account authorization alone is not enough.".into()),
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
        OAuthProvider::Tidal => Err("TIDAL playlist retrieval needs its verified API adapter; no guessed endpoint is used.".into()),
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
                "tracks": {"total": 42}
            }]
        })).unwrap();
        assert_eq!(playlists.len(), 1);
        assert_eq!(playlists[0].item_count, Some(42));
        assert_eq!(playlists[0].name, "My Mix");
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
    fn youtube_data_is_explicitly_a_separate_google_oauth_provider() {
        let settings = OAuthProvider::YoutubeData.settings();
        assert_eq!(settings.0, "RAPTOR_GOOGLE_CLIENT_ID");
        assert!(settings.4.contains("youtube.readonly"));
        assert_eq!(settings.3, "https://oauth2.googleapis.com/token");
    }
}
