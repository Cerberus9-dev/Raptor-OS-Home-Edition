use std::collections::HashMap;
use std::process::Command;
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
        let mut manager = Self { profiles: HashMap::new() };
        manager.register_profile(AppProfile {
            name: "Sober / Roblox".to_string(),
            binary_pattern: "sober".to_string(),
            force_proxy: true,
            use_udp_relay: true,
        });
        manager
    }

    pub fn register_profile(&mut self, profile: AppProfile) {
        self.profiles.insert(profile.binary_pattern.clone(), profile);
    }

    pub fn launch_with_proxy(&self, binary: &str, args: &[&str]) -> Result<(), std::io::Error> {
        let profile = self.profiles.get(binary);
        let mut cmd = Command::new(binary);
        cmd.args(args);

        if let Some(p) = profile {
            if p.force_proxy {
                cmd.env("HTTPS_PROXY", "http://127.0.0.1:10808");
                cmd.env("HTTP_PROXY", "http://127.0.0.1:10808");
                cmd.env("ALL_PROXY", "socks5://127.0.0.1:10808");
            }
        }

        let _child = cmd.spawn()?;
        Ok(())
    }
}
