# Raptor OS — Custom Bazzite Image
# Built via BlueBuild; this file is intentionally minimal.
# All customisation is declared in recipe.yml.
#
# To build locally for testing:
#   podman build -t raptor-os:local .
#
# For production, the blue-build/github-action handles everything.

FROM ghcr.io/ublue-os/bazzite:stable

# Image labels (OCI standard)
LABEL org.opencontainers.image.title="Raptor OS" \
      org.opencontainers.image.description="F-22 HUD-themed gaming Linux — Bazzite-based with automatic GPU optimisation, low-latency audio, and zero-terminal setup" \
      org.opencontainers.image.url="https://github.com/Cerberus9-dev/Raptor-OS" \
      org.opencontainers.image.source="https://github.com/Cerberus9-dev/Raptor-OS" \
      org.opencontainers.image.vendor="Cerberus9-dev" \
      org.opencontainers.image.licenses="Apache-2.0"
