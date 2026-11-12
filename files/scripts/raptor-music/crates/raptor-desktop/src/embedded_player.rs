use tao::dpi::LogicalSize;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tao::window::WindowBuilder;
use wry::WebViewBuilder;

fn youtube_html(video_id: &str) -> String {
    format!(r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Raptor Music · YouTube</title>
<style>
:root {{ color-scheme: dark; font-family: Inter, system-ui, sans-serif; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: #111811; color: #edf5e9; }}
header {{ display: flex; align-items: center; gap: 12px; padding: 12px 18px; background: #1b241b; border-bottom: 1px solid #354236; }}
.brand {{ color: #d4ed9c; font-weight: 700; letter-spacing: .08em; }}
.status {{ color: #a5b2a3; font-size: 12px; }}
main {{ display: grid; place-items: center; min-height: calc(100vh - 58px); padding: 18px; }}
.player {{ width: min(100%, 1120px); }}
.frame {{ position: relative; width: 100%; aspect-ratio: 16 / 9; background: #050805; border-radius: 10px; overflow: hidden; box-shadow: 0 16px 48px #0008; }}
iframe {{ position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }}
.controls {{ display: flex; align-items: center; gap: 10px; padding: 14px 2px; }}
button {{ border: 1px solid #52634b; background: #263324; color: #e6f1dc; border-radius: 7px; padding: 9px 15px; cursor: pointer; font: inherit; }}
button:hover {{ background: #34482a; }}
.note {{ color: #879487; font-size: 12px; margin-left: auto; }}
</style>
</head>
<body>
<header><span class="brand">RAPTOR MUSIC</span><span class="status">YouTube embedded player</span></header>
<main><section class="player">
<div class="frame"><iframe id="player" title="YouTube embedded player"
src="https://www.youtube-nocookie.com/embed/{video_id}?enablejsapi=1&playsinline=1&rel=0&controls=1"
allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe></div>
<div class="controls">
<button onclick="command('playVideo')">Play</button>
<button onclick="command('pauseVideo')">Pause</button>
<button onclick="command('stopVideo')">Stop</button>
<span class="note">Playback is provided by YouTube's official embedded player.</span>
</div>
</section></main>
<script>
function command(func) {{
 const frame = document.getElementById('player');
 frame.contentWindow.postMessage(JSON.stringify({{event:'command',func,args:[]}}), 'https://www.youtube-nocookie.com');
}}
</script>
</body></html>"#)
}

fn bandcamp_html(embed_url: &str) -> String {
    format!(r#"<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Raptor Music · Bandcamp</title>
<style>
* {{ box-sizing:border-box; }}
body {{ margin:0; min-height:100vh; display:grid; place-items:center; padding:24px; background:#111811; color:#edf5e9; font:14px Inter,system-ui,sans-serif; }}
.panel {{ width:min(100%,760px); padding:20px; border:1px solid #354236; border-radius:12px; background:#1b241b; }}
h1 {{ margin:0 0 16px; color:#d4ed9c; font-size:15px; letter-spacing:.08em; }}
iframe {{ width:100%; min-height:350px; border:0; }}
p {{ color:#a5b2a3; font-size:12px; }}
</style></head><body><section class="panel">
<h1>RAPTOR MUSIC · BANDCAMP</h1>
<iframe title="Official Bandcamp embedded player" src="{embed_url}"
seamless allow="autoplay"></iframe>
<p>Playback and availability are controlled by Bandcamp's official embedded player.</p>
</section></body></html>"#)
}

/// Opens a provider's official embedded player in a Raptor Music-owned window.
/// YouTube and Bandcamp remain responsible for their own playback permissions,
/// controls, ads, and availability; no media URLs are extracted by Raptor.
pub fn open_provider_player(provider: &str, content_id: &str) -> Result<(), String> {
    let (title, html) = match provider {
        "youtube" => {
            if content_id.len() != 11
                || !content_id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-')
            {
                return Err("YouTube returned an invalid video identifier".into());
            }
            ("Raptor Music · YouTube".to_string(), youtube_html(content_id))
        }
        "bandcamp" => {
            let url = url::Url::parse(content_id)
                .map_err(|_| "Bandcamp returned an invalid embedded-player URL".to_string())?;
            if url.scheme() != "https" || url.host_str() != Some("bandcamp.com")
                || url.query().is_some() || url.fragment().is_some()
                || !url.path().starts_with("/EmbeddedPlayer/track=")
            {
                return Err("Raptor Music only opens official Bandcamp embedded-player URLs".into());
            }
            let track_id = url.path()
                .strip_prefix("/EmbeddedPlayer/track=")
                .and_then(|value| value.split('/').next())
                .filter(|value| !value.is_empty() && value.chars().all(|ch| ch.is_ascii_digit()))
                .ok_or_else(|| "Bandcamp returned an invalid embedded track ID".to_string())?;
            let safe_embed = format!(
                "https://bandcamp.com/EmbeddedPlayer/track={track_id}/size=large/bgcol=333333/linkcol=0f91ff/tracklist=false/transparent=true/"
            );
            ("Raptor Music · Bandcamp".to_string(), bandcamp_html(&safe_embed))
        }
        _ => return Err("No embedded player is registered for this provider".into()),
    };

    std::thread::Builder::new()
        .name(format!("raptor-embedded-{provider}"))
        .spawn(move || {
            let mut builder = EventLoopBuilder::new();
            #[cfg(target_os = "linux")]
            {
                use tao::platform::unix::EventLoopBuilderExtUnix;
                builder.with_any_thread(true);
            }
            let event_loop = builder.build();
            let window = WindowBuilder::new()
                .with_title(title)
                .with_inner_size(LogicalSize::new(1100.0, 760.0))
                .build(&event_loop)
                .expect("Could not create the Raptor Music embedded-player window");
            let _webview = WebViewBuilder::new()
                .with_html(&html)
                .build(&window)
                .expect("Could not initialize the embedded provider player");
            event_loop.run(move |event, _, control_flow| {
                *control_flow = ControlFlow::Wait;
                if let Event::WindowEvent {
                    event: WindowEvent::CloseRequested,
                    ..
                } = event
                {
                    *control_flow = ControlFlow::Exit;
                }
            });
        })
        .map_err(|error| format!("Could not start the embedded player: {error}"))?;
    Ok(())
}
