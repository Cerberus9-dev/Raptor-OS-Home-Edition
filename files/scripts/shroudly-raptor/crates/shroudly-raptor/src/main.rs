mod app_manager;
mod advanced;
mod gui;

fn main() {
    if let Err(error) = gui::run() {
        eprintln!("Raptor Shroudly could not start: {error}");
        std::process::exit(1);
    }
}
