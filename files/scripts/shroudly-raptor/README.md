# Shroudly for Raptor OS

Raptor OS packages the original upstream **Shroudly** Linux desktop application by **umutxyp**, a **Codeshare Technology Ltd** product.

- Upstream repository: https://github.com/umutxyp/Shroudly
- Pinned upstream revision: `8c1ddbf4abfb3fafa73dca652830415d1b0aea7f`
- Upstream license: MIT; see `UPSTREAM-LICENSE`
- The upstream source is a Git submodule at `upstream/`.

## v3.0.0 integration

The first successful v3.0.0 main-branch image build fetches the pinned submodule, installs the Node dependencies, runs the upstream core tests and verification build, compiles the Linux Advanced-mode engine, and packages the original Electron desktop app. The image installer stages the app under `/opt/Shroudly`, installs the upstream polkit policy and icon, and adds a desktop entry.

The integration is deliberately one-time. Pull requests build and test the app but do not stage it into the image. The first successful v3.0.0 main-branch image build stages it alongside Raptor Music and creates the permanent `raptor-one-time-apps-consumed` tag only after the image is successfully built and pushed. Later image builds skip both payloads.

Installation does not enable a background service, login autostart, or automatically change the system proxy. Shroudly starts only when the user launches it; proxy/protection modes remain user-controlled and Advanced mode requests administrator authorization through the upstream polkit action.

The earlier Raptor Rust application-monitor prototype is not installed or advertised as the upstream application. Its source is retained only as a historical development artifact.

## Attribution and maintenance

Shroudly remains the work of **umutxyp** and **Codeshare Technology Ltd**. Raptor OS packages the pinned upstream source and preserves its MIT license; it does not claim authorship of the upstream application. Upstream updates should be reviewed and pinned deliberately rather than silently tracking a moving branch.
