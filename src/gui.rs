pub struct DashboardState {
    pub is_running: bool,
    pub proxy_port: u16,
    pub active_mode: String,
    pub detected_apps: usize,
}

impl DashboardState {
    pub fn new() -> Self {
        Self {
            is_running: true,
            proxy_port: 10808,
            active_mode: "Standard Loopback + Desync".into(),
            detected_apps: 2,
        }
    }

    pub fn render_summary(&self) -> String {
        format!(
            "=== Shroudly Raptor OS Edition ===\n\
             Status: {}\n\
             Local Proxy: 127.0.0.1:{}\n\
             Active Mode: {}\n\
             Monitored Apps: {}\n\
             ==================================",
            if self.is_running { "ACTIVE (Running)" } else { "STOPPED" },
            self.proxy_port,
            self.active_mode,
            self.detected_apps
        )
    }
}
