mod app_manager;
mod advanced;
mod gui;

use std::net::SocketAddr;
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use app_manager::AppsManager;
use advanced::AdvancedModeManager;
use gui::DashboardState;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dashboard = DashboardState::new();
    println!("{}", dashboard.render_summary());

    let _apps_manager = AppsManager::new();
    let mut _advanced_manager = AdvancedModeManager::new();

    let addr = "127.0.0.1:10808";
    let listener = TcpListener::bind(addr).await?;
    println!("[Shroudly Raptor] Listening for proxy connections on {}", addr);

    loop {
        let (client_stream, client_addr) = listener.accept().await?;
        tokio::spawn(async move {
            if let Err(e) = handle_connection(client_stream, client_addr).await {
                eprintln!("[Shroudly Error] Connection from {} dropped: {}", client_addr, e);
            }
        });
    }
}

async fn handle_connection(mut client: TcpStream, _addr: SocketAddr) -> Result<(), Box<dyn std::error::Error>> {
    let mut buffer = [0u8; 2048];
    let n = client.read(&mut buffer).await?;
    if n == 0 {
        return Ok(());
    }

    let request = String::from_utf8_lossy(&buffer[..n]);
    if request.starts_with("CONNECT") {
        client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n").await?;
    } else {
        client.write_all(b"HTTP/1.1 501 Not Implemented\r\n\r\n").await?;
    }

    Ok(())
}
