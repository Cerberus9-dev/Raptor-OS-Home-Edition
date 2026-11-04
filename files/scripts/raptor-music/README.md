# Raptor Music (v0.2.17)

Rust workspace for the Raptor music player.

- `raptor-core`: shared models, player events, capabilities
- `raptor-library`: SQLite library, queue and persisted state
- `raptor-audio`: decoding, resampling, channel conversion, playback worker
- `raptor-desktop`: Slint desktop app

```
cargo build --workspace && cargo test --workspace
```
