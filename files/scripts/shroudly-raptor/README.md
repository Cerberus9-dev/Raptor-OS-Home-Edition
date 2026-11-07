# Shroudly for Raptor OS

Raptor OS packages the original upstream **Shroudly** Linux desktop application by **umutxyp**, a **Codeshare Technology Ltd** product.

- Upstream repository: https://github.com/umutxyp/Shroudly
- Pinned upstream revision: `8c1ddbf4abfb3fafa73dca652830415d1b0aea7f`
- Upstream license: MIT; see `UPSTREAM-LICENSE`
- The upstream source is a Git submodule at `upstream/`.

## v3.0.0 integration

The first successful v3.0.0 main-branch image build fetches the pinned submodule, installs the Node dependencies, runs the upstream core tests and verification build, compiles the Linux Advanced-mode engine, and packages the original Electron desktop app. The image installer stages the complete Electron app and its resources under `/usr/lib/raptor/shroudly` (inside the immutable image), installs a `/usr/bin/shroudly` wrapper that launches the adjacent Electron executable, and adds the upstream polkit policy, icon, and desktop entry. `/opt` is intentionally avoided because Fedora Atomic redirects it to mutable `/var/opt`, which is not included in the committed image.

The integration is repeatable: every image build fetches the pinned upstream source, builds and tests the application, and includes the complete Shroudly payload alongside Raptor Music. The final image verification checks the launcher, Electron `app.asar`, unpacked Linux engines, desktop entry, policy, and icon.

Installation does not enable a background service, login autostart, or automatically change the system proxy. Shroudly starts only when the user launches it; proxy/protection modes remain user-controlled and Advanced mode requests administrator authorization through the upstream polkit action.

The earlier Raptor Rust application-monitor prototype is not installed or advertised as the upstream application. Its source is retained only as a historical development artifact.

## Attribution and maintenance

Shroudly remains the work of **umutxyp** and **Codeshare Technology Ltd**. Raptor OS packages the pinned upstream source and preserves its MIT license; it does not claim authorship of the upstream application. Upstream updates should be reviewed and pinned deliberately rather than silently tracking a moving branch.
