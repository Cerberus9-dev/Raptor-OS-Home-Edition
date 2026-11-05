# Raptor Music (v0.2.17)

Rust workspace for the Raptor music player.

- `raptor-core`: shared models, player events, capabilities
- `raptor-library`: SQLite library, queue and persisted state
- `raptor-audio`: decoding, resampling, channel conversion, playback worker
- `raptor-desktop`: Slint desktop app

```
cargo build --workspace && cargo test --workspace
```

## Image integration lifecycle

Raptor Music is included only in the single image build explicitly dispatched with `include_one_time_apps=true`. Normal pushes, pull requests, and scheduled image rebuilds do not compile, test, stage, or install it. The successful one-time build creates the repository lock tag `raptor-one-time-apps-consumed`; subsequent opt-in attempts are blocked. Its installer also refuses to install without the one-time staging marker.
