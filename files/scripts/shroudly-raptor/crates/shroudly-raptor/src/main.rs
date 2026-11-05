mod app_manager;
mod advanced;
mod gui;

use app_manager::AppsManager;
use advanced::AdvancedModeManager;
use gui::DashboardState;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dashboard = DashboardState::new();
    println!("{}", dashboard.render_summary());

    let _apps_manager = AppsManager::new();
    let _advanced_manager = AdvancedModeManager::new();

    println!("[Shroudly Raptor] Proxy service is disabled: upstream forwarding and the desktop dashboard are not implemented.");
    println!("[Shroudly Raptor] No local proxy port was opened and no network traffic was modified.");
    Ok(())
}
