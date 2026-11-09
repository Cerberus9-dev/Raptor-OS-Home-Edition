//! Local-only OAuth callback receiver.
//! Binds exclusively to a configured loopback IP, accepts one bounded HTTP
//! GET callback, validates OAuth state, and returns a static browser response.

use crate::provider_auth::{parse_authorization_callback, PendingAuthorization};
use std::io::{Read, Write};
use std::net::{IpAddr, TcpListener, TcpStream};
use std::time::{Duration, Instant};
use url::Url;

fn loopback_bind_address(redirect_uri: &str) -> Result<(IpAddr, u16), String> {
    let redirect = Url::parse(redirect_uri)
        .map_err(|_| "The configured OAuth callback URI is invalid".to_string())?;
    if redirect.scheme() != "http" || !redirect.username().is_empty() || redirect.password().is_some() {
        return Err("The desktop callback must use an HTTP loopback URI without credentials".into());
    }
    let host = redirect.host_str()
        .ok_or_else(|| "The OAuth callback URI has no host".to_string())?;
    let address: IpAddr = host.parse()
        .map_err(|_| "The OAuth callback host must be a literal loopback IP address".to_string())?;
    if !address.is_loopback() {
        return Err("The OAuth callback listener may only bind to loopback".into());
    }
    let port = redirect.port()
        .ok_or_else(|| "The OAuth callback URI must specify a registered port".to_string())?;
    if port == 0 {
        return Err("The OAuth callback port cannot be zero".into());
    }
    Ok((address, port))
}

fn respond(stream: &mut TcpStream, status: &str, message: &str) {
    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Raptor Music</title></head><body><p>{message}</p><p>You can close this tab and return to Raptor Music.</p></body></html>"
    );
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n{}",
        body.len(), body
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn read_request_target(stream: &mut TcpStream) -> Result<String, String> {
    stream.set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|_| "Could not configure the local callback connection".to_string())?;
    let mut request = Vec::with_capacity(1024);
    let mut chunk = [0u8; 1024];
    while request.len() < 8192 {
        let count = stream.read(&mut chunk)
            .map_err(|_| "The browser callback request could not be read".to_string())?;
        if count == 0 { break; }
        request.extend_from_slice(&chunk[..count]);
        if request.windows(4).any(|window| window == b"\r\n\r\n") { break; }
    }
    if request.len() >= 8192 {
        return Err("The browser callback request exceeded the size limit".into());
    }
    let request = std::str::from_utf8(&request)
        .map_err(|_| "The browser callback request was not valid HTTP text".to_string())?;
    let line = request.lines().next()
        .ok_or_else(|| "The browser callback request was empty".to_string())?;
    let mut parts = line.split_whitespace();
    let method = parts.next().unwrap_or_default();
    let target = parts.next().unwrap_or_default();
    let version = parts.next().unwrap_or_default();
    if method != "GET" || !version.starts_with("HTTP/1.") || !target.starts_with('/') || target.starts_with("//") {
        return Err("The local callback must be a normal HTTP GET request".into());
    }
    Ok(target.to_string())
}

/// Waits for one provider callback on the configured loopback redirect URI.
/// Call this from a worker thread; it blocks for at most the supplied timeout.
pub fn wait_for_authorization_code(
    pending: &PendingAuthorization,
    timeout: Duration,
) -> Result<String, String> {
    let (address, port) = loopback_bind_address(&pending.redirect_uri)?;
    let listener = TcpListener::bind((address, port))
        .map_err(|_| "Could not open the registered local callback port; close another app using it and retry".to_string())?;
    listener.set_nonblocking(true)
        .map_err(|_| "Could not configure the local callback listener".to_string())?;
    let deadline = Instant::now() + timeout;
    loop {
        match listener.accept() {
            Ok((mut stream, peer)) => {
                if !peer.ip().is_loopback() {
                    respond(&mut stream, "403 Forbidden", "This callback is not permitted.");
                    continue;
                }
                let target = match read_request_target(&mut stream) {
                    Ok(target) => target,
                    Err(error) => {
                        respond(&mut stream, "400 Bad Request", "The sign-in response could not be read.");
                        return Err(error);
                    }
                };
                let host = match address {
                    IpAddr::V4(ip) => ip.to_string(),
                    IpAddr::V6(ip) => format!("[{ip}]"),
                };
                let callback = format!("http://{host}:{port}{target}");
                match parse_authorization_callback(&callback, pending) {
                    Ok(code) => {
                        respond(&mut stream, "200 OK", "Sign-in received successfully.");
                        return Ok(code);
                    }
                    Err(error) => {
                        respond(&mut stream, "400 Bad Request", "Sign-in could not be verified. Return to Raptor Music and try again.");
                        return Err(format!("Provider callback rejected: {error}"));
                    }
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() >= deadline {
                    return Err("Timed out waiting for the provider sign-in callback".into());
                }
                std::thread::sleep(Duration::from_millis(40));
            }
            Err(_) => return Err("The local provider callback listener stopped unexpectedly".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callback_listener_only_accepts_literal_loopback_hosts() {
        assert_eq!(
            loopback_bind_address("http://127.0.0.1:43821/callback").unwrap(),
            ("127.0.0.1".parse().unwrap(), 43821)
        );
        assert!(loopback_bind_address("http://192.168.1.5:43821/callback").is_err());
        assert!(loopback_bind_address("http://localhost:43821/callback").is_err());
        assert!(loopback_bind_address("https://127.0.0.1:43821/callback").is_err());
        assert!(loopback_bind_address("http://127.0.0.1/callback").is_err());
    }
}
