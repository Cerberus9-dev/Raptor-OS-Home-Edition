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
    fn token_response_parser_keeps_refresh_and_identity_tokens_optional() {
        let response: OAuthTokenResponse = serde_json::from_str(
            r#"{"access_token":"access","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh","scope":"read","id_token":"identity"}"#
        ).expect("valid token response");
        assert_eq!(response.access_token, "access");
        assert_eq!(response.refresh_token.as_deref(), Some("refresh"));
        assert_eq!(response.id_token.as_deref(), Some("identity"));
    }

    #[test]
    fn youtube_data_is_explicitly_a_separate_google_oauth_provider() {
        let settings = OAuthProvider::YoutubeData.settings();
        assert_eq!(settings.0, "RAPTOR_GOOGLE_CLIENT_ID");
        assert!(settings.4.contains("youtube.readonly"));
        assert_eq!(settings.3, "https://oauth2.googleapis.com/token");
    }
}
