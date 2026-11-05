# Shroudly Raptor

Raptor's Shroudly integration is based on the complete upstream **Shroudly**
project by **umutxyp**, a **Codeshare Technology Ltd** product.

- Upstream: https://github.com/umutxyp/Shroudly
- Pinned source: [upstream/](upstream/)
- Upstream revision: `8c1ddbf4abfb3fafa73dca652830415d1b0aea7f`
- License: MIT; see [UPSTREAM-LICENSE](UPSTREAM-LICENSE) and the upstream
  repository's own `LICENSE`.

The upstream repository is included as a Git submodule rather than copied into
a partial reimplementation. This retains its original directory structure,
source files, build scripts, tests, Linux integration, and platform-specific
code while keeping the upstream revision traceable. GitHub Actions checks out
submodules recursively and verifies the key upstream source and license files.

## Integration status

The complete upstream source is now pinned in this repository. The current
Raptor OS image build still contains the earlier Rust monitoring prototype;
that prototype is transitional and is not the final Shroudly Raptor
implementation. The original upstream desktop application and Linux engine
have not yet been wired into the Raptor image build.

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
