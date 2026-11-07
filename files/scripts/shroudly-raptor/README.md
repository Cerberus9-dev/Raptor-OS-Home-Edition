# Raptor Shroudly

Raptor Shroudly is the **custom Raptor OS application**, built from the Rust source in this directory. It is not the upstream Electron desktop app and does not substitute the upstream application for the Raptor implementation.

## Current implementation

- Native Slint desktop dashboard with Raptor OS styling.
- Detects supported game clients and desktop apps from the local process table.
- Supports detection labels for Sober, Roblox, Steam, Heroic, Lutris, Bottles, Gamescope, Prism Launcher, Modrinth, ATLauncher, GDLauncher, Minecraft, r2modman, itch, Discord and Firefox/Vesktop.
- Refreshes detection on demand.
- Does not freeze, kill, suspend, or modify detected applications.

**Important:** network routing, proxy/tunnel operation, packet redirection and per-app traffic steering are not implemented in this build. The application says so directly; it does not claim protection is active or modify firewall rules. Those features need a real routing engine, isolated firewall ownership, cleanup/recovery behavior, and integration tests before they can be enabled.

## Build and test

```sh
cargo build --release --workspace
cargo test --workspace
```

CI builds the custom executable for every Raptor OS image and verifies that the binary, desktop entry and icon are present inside the published image.

## Relationship to upstream

Raptor Shroudly is inspired by the original Shroudly project by **umutxyp / Codeshare Technology Ltd**. The upstream project is not bundled or presented as the Raptor application. Any upstream-derived code or assets must retain their applicable license and attribution; the custom Raptor implementation remains separately identifiable.
