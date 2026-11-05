use std::collections::BTreeSet;
use std::fs;

/// This dashboard reports only locally observed process state. It deliberately
/// does not claim that a proxy, tunnel, or packet mode is running.
pub struct DashboardState {
    pub is_running: bool,
    pub proxy_port: Option<u16>,
    pub active_mode: String,
    pub detected_apps: Vec<String>,
}

impl DashboardState {
    pub fn new() -> Self {
        Self {
            is_running: false,
            proxy_port: None,
            active_mode: "Local monitoring only".into(),
            detected_apps: detect_supported_apps(),
        }
    }

    pub fn render_summary(&self) -> String {
        let apps = if self.detected_apps.is_empty() {
            "None detected".to_string()
        } else {
            self.detected_apps.join(", ")
        };

        format!(
            "=== Shroudly Raptor ===\n\
             Network service: Not running\n\
             Local proxy: Not available\n\
             Mode: {}\n\
             Supported apps detected: {}\n\
             Apps: {}\n\
             ========================",
            self.active_mode,
            self.detected_apps.len(),
            apps
        )
    }
}

fn classify_process_name(name: &str) -> Option<&'static str> {
    let name = name.to_ascii_lowercase();
    let patterns: &[(&str, &str)] = &[
        ("sober", "Sober"),
        ("roblox", "Roblox"),
        ("steam", "Steam"),
        ("heroic", "Heroic"),
        ("lutris", "Lutris"),
        ("bottles", "Bottles"),
        ("gamescope", "Gamescope"),
        ("prismlauncher", "Prism Launcher"),
        ("modrinth", "Modrinth App"),
        ("atlauncher", "ATLauncher"),
        ("gdlauncher", "GDLauncher"),
        ("minecraft", "Minecraft"),
        ("r2modman", "r2modman"),
        ("itch", "itch"),
        ("discord", "Discord"),
    ];

    patterns.iter()
        .find_map(|(pattern, label)| name.contains(pattern).then_some(*label))
}

fn detect_supported_apps() -> Vec<String> {
    let mut found = BTreeSet::new();

    #[cfg(target_os = "linux")]
    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let file_name = entry.file_name();
            if !file_name.to_string_lossy().chars().all(|c| c.is_ascii_digit()) {
                continue;
            }

            if let Ok(name) = fs::read_to_string(entry.path().join("comm")) {
                if let Some(label) = classify_process_name(name.trim()) {
                    found.insert(label.to_string());
                }
            }
        }
    }

    found.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::classify_process_name;

    #[test]
    fn recognizes_supported_game_clients_case_insensitively() {
        assert_eq!(classify_process_name("PrismLauncher"), Some("Prism Launcher"));
        assert_eq!(classify_process_name("sober"), Some("Sober"));
        assert_eq!(classify_process_name("Heroic"), Some("Heroic"));
    }

    #[test]
    fn ignores_unrelated_processes() {
        assert_eq!(classify_process_name("firefox"), None);
        assert_eq!(classify_process_name("systemd"), None);
    }
}
