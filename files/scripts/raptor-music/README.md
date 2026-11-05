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

Raptor Music is staged only for the first successful v3.0.0 image build on `main`, when the release marker is present. Pull requests, unrelated pushes, and scheduled rebuilds skip the app. A maintainer-only manual dispatch remains as a recovery fallback. The lock tag `raptor-one-time-apps-consumed` is created only after the image is successfully built and pushed. Its installer refuses to install without the one-time staging marker.
