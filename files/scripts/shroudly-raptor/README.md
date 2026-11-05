# Shroudly Raptor

Raptor's Shroudly integration is based on the complete upstream **Shroudly**
project by **umutxyp**, a **Codeshare Technology Ltd** product.

- Pinned source: [upstream/](upstream/)
- Upstream revision: `8c1ddbf4abfb3fafa73dca652830415d1b0aea7f`
- License: MIT; see [UPSTREAM-LICENSE](UPSTREAM-LICENSE) and the upstream
  repository's own `LICENSE`.

The upstream repository is included as a Git submodule rather than copied into
a partial reimplementation. This retains its original directory structure,
source files, build scripts, tests, Linux integration, and platform-specific
code while keeping the upstream revision traceable. GitHub Actions fetches the pinned submodule and verifies the key upstream source and license files only during the explicitly requested one-time image build.

## Integration status

Shroudly is not installed in the Raptor OS v3.0.0 image. The incomplete local Rust monitoring prototype remains in the repository as a development artifact only; it is not installed, exposed as a proxy, or advertised as the original upstream Shroudly application. The upstream network-filter circumvention engine is not built, fetched, or installed.

Do not describe the transitional Rust binary as a complete Shroudly port.
Raptor-specific work will be applied as a clearly documented patch layer over
the upstream project, rather than replacing its architecture or discarding
its original files.

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

Shroudly is not installed or staged in v3.0.0. The current local-monitor prototype is incomplete and is not presented as a working proxy or as the original Shroudly application. The upstream network-filter circumvention engine is not built, fetched, or installed.
