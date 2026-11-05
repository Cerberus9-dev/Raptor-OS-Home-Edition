mod app_manager;
mod advanced;
mod gui;

use gui::DashboardState;

fn main() {
    let dashboard = DashboardState::new();
    println!("{}", dashboard.render_summary());
    println!();
    println!("[Shroudly Raptor] Network routing and packet processing are not enabled.");
    println!("[Shroudly Raptor] Detected applications are informational only; no traffic is redirected.");
}
