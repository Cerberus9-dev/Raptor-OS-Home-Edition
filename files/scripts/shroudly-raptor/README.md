# Shroudly Raptor

Raptor's Shroudly integration is based on the complete upstream **Shroudly**
project by **umutxyp**, a **Codeshare Technology Ltd** product.

- Upstream: https://github.com/umutxyp/Shroudly
- Pinned source: [upstream/](upstream/)
- Upstream revision: `8c1ddbf4abfb3fafa73dca652830415d1b0aea7f`
- License: MIT; see [UPSTREAM-LICENSE](UPSTREAM-LICENSE) and the upstream
  repository's own `LICENSE`.

The upstream repository is included as a pinned Git submodule rather than copied into a partial reimplementation. The first successful v3.0.0 main-branch image build compiles its Linux desktop app, normal engine, and Advanced-mode engine from that source, then stages the unpacked Electron application, icon, license, and polkit action. Pull-request builds and later image builds do not stage or install this one-time payload.

## Integration status

The original upstream desktop application and Linux engines are the v3.0.0 integration target. The previous Rust monitoring prototype is no longer installed; its source remains only as a historical development artifact. The v3.0.0 build verifies the upstream app, both Linux engine binaries, their linked libraries, the desktop entry, and the polkit action before image installation.

Do not describe Raptor as the upstream Shroudly author. Raptor packages the pinned upstream project and keeps attribution and licensing intact; any Raptor-specific changes must remain a clearly documented patch layer over upstream.

## Raptor improvement goals

- Preserve the original Shroudly desktop UI, settings, engine architecture,
  Linux desktop integration, and upstream behavior.
- Improve KDE Plasma integration and compatibility with other supported
  Linux desktops.
- Improve startup, shutdown, diagnostics, logging, and error recovery.
- Reduce unnecessary background resource use without removing useful
  functionality.
- Make application state and capability reporting accurate.
- Keep Raptor-specific changes isolated and documented so upstream updates
  can be reviewed and merged deliberately.

## Attribution

Shroudly is maintained by **umutxyp** and is a product of
**Codeshare Technology Ltd**. The upstream MIT license and copyright notice
are preserved. Raptor OS is an independent downstream integration, not an
official upstream release and not endorsed by Codeshare Technology Ltd.

## Image integration lifecycle

The transitional Shroudly monitor prototype is staged only for the first successful v3.0.0 image build on `main`, when the release marker is present. Pull requests, unrelated pushes, and scheduled rebuilds skip it. A maintainer-only manual dispatch remains as a recovery fallback. The lock tag `raptor-one-time-apps-consumed` is created only after the image is successfully built and pushed. Its installer refuses to install without the one-time staging marker. The original upstream Linux application is not yet integrated.
