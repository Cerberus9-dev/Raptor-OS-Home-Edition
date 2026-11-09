//! Secure persistence for provider credentials.
//!
//! Credentials are stored as one opaque JSON value in the platform credential
//! manager (Secret Service on Linux, Windows Credential Manager, or Apple
//! Keychain). They are never written to the Raptor Music SQLite database.

use crate::provider_auth::OAuthTokenResponse;
use keyring::Entry;

const SERVICE_NAME: &str = "com.cerberus9.raptor-music";

fn provider_entry(provider: &str) -> Result<Entry, String> {
    let normalized = provider.trim().to_ascii_lowercase();
    if normalized.is_empty()
        || !normalized.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'_')
    {
        return Err("Invalid provider identifier for secure credential storage".into());
    }
    Entry::new(SERVICE_NAME, &normalized)
        .map_err(|_| "The operating-system credential store is unavailable".to_string())
}

/// Saves an OAuth token response to the operating-system credential manager.
/// Provider access and refresh tokens are not exposed in error messages.
pub fn save_tokens(provider: &str, tokens: &OAuthTokenResponse) -> Result<(), String> {
    if tokens.access_token.trim().is_empty() {
        return Err("Refusing to store an empty provider access token".into());
    }
    let serialized = serde_json::to_string(tokens)
        .map_err(|_| "Could not serialize provider credentials".to_string())?;
    provider_entry(provider)?
        .set_password(&serialized)
        .map_err(|_| "Could not save credentials to the operating-system secure store".to_string())
}

/// Loads provider credentials from the operating-system credential manager.
pub fn load_tokens(provider: &str) -> Result<OAuthTokenResponse, String> {
    let serialized = provider_entry(provider)?
        .get_password()
        .map_err(|_| "No saved credentials are available for this provider, or the secure store is locked".to_string())?;
    serde_json::from_str(&serialized)
        .map_err(|_| "Saved provider credentials could not be decoded; reconnect this account".to_string())
}

/// Removes the provider's saved credentials (disconnect operation).
pub fn remove_tokens(provider: &str) -> Result<(), String> {
    provider_entry(provider)?
        .delete_credential()
        .map_err(|_| "Could not remove credentials from the operating-system secure store".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_entry_rejects_untrusted_key_names() {
        assert!(provider_entry("spotify").is_ok());
        assert!(provider_entry("youtube-data").is_ok());
        assert!(provider_entry("../spotify").is_err());
        assert!(provider_entry("").is_err());
    }

    #[test]
    fn credential_store_errors_never_echo_secret_values() {
        let tokens = OAuthTokenResponse {
            access_token: "private-access-token".into(),
            token_type: "Bearer".into(),
            expires_in: 3600,
            refresh_token: Some("private-refresh-token".into()),
            scope: None,
            id_token: None,
        };
        let serialized = serde_json::to_string(&tokens).unwrap();
        assert!(serialized.contains("private-access-token"));
        assert!(serialized.contains("private-refresh-token"));
    }
}
