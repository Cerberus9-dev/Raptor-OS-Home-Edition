/// Advanced packet-level mode is intentionally unavailable until Shroudly
/// has a dedicated, isolated nftables table and matching cleanup logic.
///
/// Never flush the global nftables ruleset here: that would delete firewall,
/// container, VPN, and other applications' network rules.
pub struct AdvancedModeManager;

impl AdvancedModeManager {
    pub fn new() -> Self {
        Self
    }

    pub fn enable_packet_mode(&mut self) -> Result<(), String> {
        Err(
            "Advanced packet mode is not implemented; no nftables rules were changed."
                .into(),
        )
    }

    pub fn cleanup(&mut self) {
        // No packet-mode rules are installed by this implementation.
    }
}
