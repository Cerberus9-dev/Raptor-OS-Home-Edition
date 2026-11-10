//! Apple Music MusicKit-on-the-Web sign-in bridge for desktop Linux.
//! Apple's hosted authorization UI is used; passwords never pass through Raptor Music.
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};
use uuid::Uuid;

const MAX_BODY: usize = 20 * 1024;

fn respond(stream: &mut TcpStream, status: &str, content_type: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\nPragma: no-cache\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'self' 'unsafe-inline' https://js-cdn.music.apple.com; connect-src 'self'; style-src 'unsafe-inline'; base-uri 'none'\r\n\r\n{}",
        body.len(), body
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn auth_page(developer_token: &str, state: &str) -> String {
    format!(r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Connect Apple Music · Raptor Music</title>
<style>body{{font:16px system-ui;background:#111811;color:#eef3e8;max-width:38rem;margin:12vh auto;padding:2rem}}p{{color:#b7c4b2}}button{{padding:.8rem 1.2rem;border:0;border-radius:.6rem;background:#c8f27b;color:#15200e;font-weight:700}}</style>
<script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js"></script></head><body>
<h1>Connect Apple Music</h1><p>Sign in using Apple's official authorization. Your Apple password is entered only on Apple's service.</p>
<button id="connect" disabled>Loading Apple Music…</button><p id="status">Waiting for MusicKit…</p>
<script>
const developerToken="{developer_token}", state="{state}";
const button=document.getElementById("connect"), status=document.getElementById("status");
async function connect() {{
 button.disabled=true; status.textContent="Opening Apple's authorization…";
 try {{
  const music=MusicKit.getInstance(); await music.authorize();
  const userToken=music.musicUserToken;
  if(!userToken || typeof userToken!=="string") throw new Error("Apple did not return a Music User Token.");
  status.textContent="Returning securely to Raptor Music…";
  const response=await fetch("/callback",{{method:"POST",headers:{{"Content-Type":"application/json"}},body:JSON.stringify({{state,userToken}})}});
  if(!response.ok) throw new Error("Raptor Music could not verify the sign-in response.");
  status.textContent="Apple Music connected. Return to Raptor Music."; button.textContent="Connected";
 }} catch(error) {{
  status.textContent=error && error.message ? error.message : "Authorization was cancelled or failed.";
  button.disabled=false; button.textContent="Try again";
 }}
}}
window.addEventListener("load",async()=>{{
 try {{
  await MusicKit.configure({{developerToken,app:{{name:"Raptor Music",build:"0.2.18"}}}});
  button.disabled=false; button.textContent="Sign in with Apple Music"; button.addEventListener("click",connect);
 }} catch(_) {{ status.textContent="MusicKit could not initialize. Check the developer token and connection."; }}
}});
</script></body></html>"#)
}

struct Request { method:String, target:String, headers:Vec<(String,String)>, body:Vec<u8> }

fn read_request(stream: &mut TcpStream) -> Result<Request,String> {
    stream.set_read_timeout(Some(Duration::from_secs(5))).map_err(|_| "Could not configure callback socket")?;
    let mut bytes=Vec::new(); let mut chunk=[0u8;2048]; let mut header_end=None; let mut length=0usize;
    loop {
        let n=stream.read(&mut chunk).map_err(|_| "Could not read Apple Music callback")?;
        if n==0 { break; }
        bytes.extend_from_slice(&chunk[..n]);
        if bytes.len()>MAX_BODY+8192 { return Err("Apple Music callback exceeded its size limit".into()); }
        if header_end.is_none() {
            if let Some(i)=bytes.windows(4).position(|w|w==b"\r\n\r\n") {
                let h=std::str::from_utf8(&bytes[..i]).map_err(|_|"Invalid callback headers")?;
                for line in h.lines().skip(1) {
                    if let Some((k,v))=line.split_once(':') { if k.eq_ignore_ascii_case("content-length") { length=v.trim().parse().map_err(|_|"Invalid callback length")?; } }
                }
                if length>MAX_BODY { return Err("Apple Music callback body too large".into()); }
                header_end=Some(i+4);
            }
        }
        if let Some(end)=header_end { if bytes.len()>=end+length { break; } }
    }
    let end=header_end.ok_or("Missing HTTP header terminator")?;
    if bytes.len()<end+length { return Err("Incomplete Apple Music callback body".into()); }
    let h=std::str::from_utf8(&bytes[..end-4]).map_err(|_|"Invalid callback headers")?;
    let mut lines=h.lines(); let mut first=lines.next().unwrap_or_default().split_whitespace();
    let method=first.next().unwrap_or_default().to_string();
    let target=first.next().unwrap_or_default().to_string();
    let version=first.next().unwrap_or_default();
    if !version.starts_with("HTTP/1.") || !target.starts_with('/') || target.starts_with("//") { return Err("Invalid callback request line".into()); }
    let headers=lines.filter_map(|line| { let (k,v)=line.split_once(':')?; Some((k.trim().to_ascii_lowercase(),v.trim().to_string())) }).collect();
    Ok(Request{method,target,headers,body:bytes[end..end+length].to_vec()})
}

pub struct AppleMusicAuthListener { listener:TcpListener, port:u16, state:String, page:String }

impl AppleMusicAuthListener {
    pub fn bind(developer_token:&str)->Result<Self,String> {
        let token=developer_token.trim();
        if token.is_empty() || token.len()>8192 || !token.bytes().all(|b|b.is_ascii_alphanumeric()||matches!(b,b'.'|b'_'|b'-')) {
            return Err("Apple Music developer token is malformed; provide a signed ES256 token".into());
        }
        let listener=TcpListener::bind(("127.0.0.1",0)).map_err(|_|"Could not open a private local Apple Music callback")?;
        listener.set_nonblocking(true).map_err(|_|"Could not configure Apple Music callback")?;
        let port=listener.local_addr().map_err(|_|"Could not determine callback port")?.port();
        let state=Uuid::new_v4().simple().to_string();
        let page=auth_page(token,&state);
        Ok(Self{listener,port,state,page})
    }
    pub fn authorization_url(&self)->String { format!("http://127.0.0.1:{}/?state={}",self.port,self.state) }
    pub fn wait_for_user_token(self,timeout:Duration)->Result<String,String> {
        let deadline=Instant::now()+timeout;
        loop {
            match self.listener.accept() {
                Ok((mut stream,peer))=>{
                    if peer.ip()!=std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST) { respond(&mut stream,"403 Forbidden","text/plain","Forbidden"); continue; }
                    let req=match read_request(&mut stream) { Ok(v)=>v,Err(e)=>{respond(&mut stream,"400 Bad Request","text/plain","Invalid callback");return Err(e);} };
                    let host=format!("127.0.0.1:{}",self.port);
                    if !req.headers.iter().any(|(k,v)|k=="host"&&v==&host) { respond(&mut stream,"403 Forbidden","text/plain","Invalid host");continue; }
                    if req.method=="GET" && req.target==format!("/?state={}",self.state) {
                        respond(&mut stream,"200 OK","text/html; charset=utf-8",&self.page); continue;
                    }
                    if req.method!="POST" || req.target!="/callback" { respond(&mut stream,"404 Not Found","text/plain","Not found");continue; }
                    let origin=format!("http://127.0.0.1:{}",self.port);
                    if !req.headers.iter().any(|(k,v)|k=="origin"&&v==&origin)
                        || !req.headers.iter().any(|(k,v)|k=="content-type"&&v.starts_with("application/json")) {
                        respond(&mut stream,"403 Forbidden","text/plain","Invalid origin");continue;
                    }
                    let payload:serde_json::Value=serde_json::from_slice(&req.body).map_err(|_|"Invalid Apple Music authorization payload")?;
                    let state=payload.get("state").and_then(serde_json::Value::as_str).unwrap_or_default();
                    let token=payload.get("userToken").and_then(serde_json::Value::as_str).unwrap_or_default();
                    if state!=self.state || token.is_empty() || token.len()>MAX_BODY || token.chars().any(char::is_control) {
                        respond(&mut stream,"400 Bad Request","text/plain","Sign-in could not be verified");
                        return Err("Apple Music sign-in failed state or token validation".into());
                    }
                    respond(&mut stream,"200 OK","text/plain; charset=utf-8","Apple Music connected. Return to Raptor Music.");
                    return Ok(token.to_string());
                }
                Err(e) if e.kind()==std::io::ErrorKind::WouldBlock=>{
                    if Instant::now()>=deadline { return Err("Timed out waiting for Apple Music authorization".into()); }
                    std::thread::sleep(Duration::from_millis(40));
                }
                Err(_)=>return Err("Apple Music sign-in listener stopped unexpectedly".into()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn validates_developer_token_before_embedding(){ assert!(AppleMusicAuthListener::bind("header.payload.signature").is_ok()); assert!(AppleMusicAuthListener::bind("bad token").is_err()); assert!(AppleMusicAuthListener::bind("<script>").is_err()); }
    #[test] fn uses_apple_hosted_musickit_and_one_use_state(){ let page=auth_page("header.payload.signature","state-123"); assert!(page.contains("https://js-cdn.music.apple.com/musickit/v3/musickit.js")); assert!(page.contains("await music.authorize()")); assert!(page.contains("music.musicUserToken")); assert!(page.contains("fetch(\"/callback\"")); assert!(!page.contains("localStorage")); }
    #[test] fn binds_loopback_and_creates_random_state(){ let listener=AppleMusicAuthListener::bind("header.payload.signature").unwrap(); assert!(listener.authorization_url().starts_with("http://127.0.0.1:")); assert_eq!(listener.state.len(),32); }
    #[test]
    fn loopback_callback_returns_only_token_with_matching_state_and_origin() {
        use std::net::TcpStream;
        use std::io::{Read, Write};

        let listener = AppleMusicAuthListener::bind("header.payload.signature").unwrap();
        let callback_url = listener.authorization_url();
        let parsed = url::Url::parse(&callback_url).unwrap();
        let port = parsed.port().unwrap();
        let state = listener.state.clone();
        let worker = std::thread::spawn(move || listener.wait_for_user_token(Duration::from_secs(5)));

        let mut page = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(page, "GET /?state={state} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n").unwrap();
        let mut page_response = String::new();
        page.read_to_string(&mut page_response).unwrap();
        assert!(page_response.starts_with("HTTP/1.1 200 OK"));
        assert!(page_response.contains("MusicKit.getInstance()"));

        let body = serde_json::json!({"state": state, "userToken": "apple-user-token"}).to_string();
        let mut callback = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(
            callback,
            "POST /callback HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: http://127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(), body
        ).unwrap();
        let mut response = String::new();
        callback.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200 OK"));
        assert_eq!(worker.join().unwrap().unwrap(), "apple-user-token");
    }

}