use std::collections::BTreeSet;
use std::fs;

slint::slint! {
    import { Button } from "std-widgets.slint";

    export component ShroudlyWindow inherits Window {
        title: "Raptor Shroudly";
        width: 820px;
        height: 600px;
        background: #0b1420;

        in-out property <string> detected_apps: "Scanning…";
        in-out property <string> detected_count: "0 applications detected";
        callback refresh_requested();

        VerticalLayout {
            padding: 24px;
            spacing: 16px;

            HorizontalLayout {
                spacing: 12px;
                Text {
                    text: "RAPTOR / SHROUDLY";
                    color: #8bd4f1;
                    font-size: 26px;
                    font-weight: 700;
                    vertical-alignment: center;
                }
                Rectangle { horizontal-stretch: 1; }
                Text {
                    text: "V3 • HOME";
                    color: #8093a8;
                    font-size: 12px;
                    vertical-alignment: center;
                }
            }

            Text {
                text: "Application compatibility dashboard";
                color: #f0f5fa;
                font-size: 21px;
                font-weight: 600;
            }
            Text {
                text: "Raptor Shroudly is the Raptor-customized application monitor. It identifies supported game clients and desktop apps without suspending or modifying them.";
                color: #b5c4d3;
                font-size: 14px;
                wrap: word-wrap;
            }

            Rectangle {
                background: #142638;
                border-radius: 12px;
                padding: 18px;
                VerticalLayout {
                    spacing: 8px;
                    Text {
                        text: "LIVE APPLICATION DETECTION";
                        color: #8bd4f1;
                        font-size: 12px;
                        font-weight: 700;
                    }
                    Text {
                        text: root.detected_count;
                        color: #f0f5fa;
                        font-size: 22px;
                        font-weight: 600;
                    }
                    Text {
                        text: root.detected_apps;
                        color: #c8d7e6;
                        font-size: 14px;
                        wrap: word-wrap;
                    }
                    Button {
                        text: "Refresh running applications";
                        clicked => { root.refresh_requested(); }
                    }
                }
            }

            Rectangle {
                background: #19212d;
                border-radius: 10px;
                padding: 16px;
                VerticalLayout {
                    spacing: 8px;
                    Text {
                        text: "NETWORK STATUS";
                        color: #8bd4f1;
                        font-size: 12px;
                        font-weight: 700;
                    }
                    Text {
                        text: "Traffic routing is not enabled in this build.";
                        color: #f0f5fa;
                        font-size: 16px;
                        font-weight: 600;
                    }
                    Text {
                        text: "No proxy, tunnel, firewall rule, or packet redirection is activated. App detection is informational only; network protection controls will appear here when the Raptor routing engine is implemented and tested.";
                        color: #b5c4d3;
                        font-size: 13px;
                        wrap: word-wrap;
                    }
                }
            }

            Rectangle { vertical-stretch: 1; }
            Text {
                text: "Raptor OS • Local-first • No background service";
                color: #71859a;
                font-size: 11px;
            }
        }
    }
}

pub struct DashboardState {
    pub detected_apps: Vec<String>,
}

impl DashboardState {
    pub fn new() -> Self {
        Self { detected_apps: detect_supported_apps() }
    }

    pub fn render_summary(&self) -> String {
        if self.detected_apps.is_empty() {
            "No supported applications detected.".to_string()
        } else {
            self.detected_apps.join(", ")
        }
    }
}

fn classify_process_name(name: &str) -> Option<&'static str> {
    let name = name.to_ascii_lowercase();
    let patterns: &[(&str, &str)] = &[
        ("sober", "Sober"),
        ("roblox", "Roblox"),
        ("steam", "Steam"),
        ("heroic", "Heroic Games Launcher"),
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
        ("firefox", "Firefox"),
        ("vesktop", "Vesktop"),
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

pub fn run() -> Result<(), slint::PlatformError> {
    let ui = ShroudlyWindow::new()?;
    let initial = DashboardState::new();
    ui.set_detected_count(format!("{} applications detected", initial.detected_apps.len()).into());
    ui.set_detected_apps(initial.render_summary().into());

    let weak = ui.as_weak();
    ui.on_refresh_requested(move || {
        let state = DashboardState::new();
        if let Some(ui) = weak.upgrade() {
            ui.set_detected_count(format!("{} applications detected", state.detected_apps.len()).into());
            ui.set_detected_apps(state.render_summary().into());
        }
    });

    ui.run()
}

#[cfg(test)]
mod tests {
    use super::classify_process_name;

    #[test]
    fn recognizes_supported_clients_case_insensitively() {
        assert_eq!(classify_process_name("PrismLauncher"), Some("Prism Launcher"));
        assert_eq!(classify_process_name("sober"), Some("Sober"));
        assert_eq!(classify_process_name("Heroic"), Some("Heroic Games Launcher"));
        assert_eq!(classify_process_name("steamwebhelper"), Some("Steam"));
        assert_eq!(classify_process_name("firefox"), Some("Firefox"));
    }

    #[test]
    fn ignores_unrelated_processes() {
        assert_eq!(classify_process_name("systemd"), None);
        assert_eq!(classify_process_name("kwin_wayland"), None);
    }
}
