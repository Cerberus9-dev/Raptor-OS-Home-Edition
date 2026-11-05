use std::collections::HashMap;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct AppProfile {
    pub name: String,
    pub binary_pattern: String,
    pub force_proxy: bool,
    pub use_udp_relay: bool,
}

pub struct AppsManager {
    profiles: HashMap<String, AppProfile>,
}

impl AppsManager {
    pub fn new() -> Self {
        Self { profiles: HashMap::new() }
    }

    pub fn register_profile(&mut self, profile: AppProfile) {
        self.profiles.insert(profile.binary_pattern.clone(), profile);
    }

    /// Launch-through-proxy is unavailable until a real upstream proxy exists.
    /// Return an explicit error rather than silently sending apps to a dead port.
    pub fn launch_with_proxy(&self, _binary: &str, _args: &[&str]) -> Result<(), std::io::Error> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "Shroudly proxy forwarding is not implemented; application launch was not attempted",
        ))
    }
}
