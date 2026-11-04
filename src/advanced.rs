use std::process::Command;

pub struct AdvancedModeManager {
    active: bool,
}

impl AdvancedModeManager {
    pub fn new() -> Self {
        Self { active: false }
    }

    pub fn enable_packet_mode(&mut self) -> Result<(), String> {
        let status = Command::new("nft").arg("--version").status();
        match status {
            Ok(s) if s.success() => {
                self.active = true;
                Ok(())
            }
            _ => Err("Netfilter/nftables utility not accessible in current context.".into()),
        }
    }

    pub fn cleanup(&mut self) {
        if self.active {
            let _ = Command::new("nft").args(["flush", "ruleset"]).status();
            self.active = false;
        }
    }
}

impl Drop for AdvancedModeManager {
    fn drop(&mut self) {
        self.cleanup();
    }
}
