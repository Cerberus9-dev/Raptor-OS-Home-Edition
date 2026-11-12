# Raptor OS

**Current version:** v3.0.0

Raptor OS is a Bazzite-based Linux distribution with KDE Plasma. It uses an atomic system image and includes tools for updates, hardware controls, local music, and task management.

> **Before installing:** Back up important files. Test Raptor OS in a virtual machine or on a separate drive first. Allow at least 50 GB for a dual-boot installation. The OCI image build and fresh-install ISO build are separate; use only an ISO and checksum published on the official release page.

## Project goals

- **Desktop-first setup:** updates, app installation, hardware settings, and recovery should be accessible through graphical tools.
- **Keep the base reliable:** use the atomic update model and retain a rollback path. Avoid system-wide tweaks that trade stability for small benchmark gains.
- **Windows app support:** use Wine for ordinary Windows programs and the optional Proton/UMU path for games. Compatibility depends on the application.
- **Hardware support:** test Wi-Fi, Bluetooth, graphics, audio, controllers, sleep and resume on real hardware before describing a fix as complete.
- **Measured performance changes:** make changes only when there is a clear benefit, and avoid disabling services that other desktop or gaming features need.
- **Optional software:** let users choose browsers, chat clients, and other apps instead of installing a large default bundle.
- **Document limitations:** distinguish tested hardware and features from work that is still being developed.

This README covers Home Edition. Security Edition has a separate repository, toolset, and configuration.

### Recovery

Raptor Update Manager can stage a rollback to the previous OSTree deployment when one is available. It does not roll back Flatpak versions, personal files, or every setting in the home directory.

### Raptor desktop apps

Raptor Tasks stores tasks locally with search and filters. Raptor Wallpaper provides a searchable gallery and can set the desktop or lock-screen image. Raptor Music is moving to a wrapper-first design: Raptor provides the unified interface, library, queue, metadata model and playback controls, while provider adapters connect supported Spotify, YouTube and Bandcamp experiences. The UI stays independent of provider APIs and audio-engine details. Local files remain a first-class source. Existing Audius, Jamendo and Apple Music discovery/playback integrations are optional catalogue connectors rather than requirements for the core app; they can remain available where useful, but they are not the foundation of the wrapper architecture. Provider linking or metadata access does not grant full-track playback rights, so each integration must use the provider's supported player, handoff or authorized stream path. The normalized `UnifiedTrack`, `AudioSource` and `AudioBackend` layers keep those differences behind the app's provider and playback boundaries.

---

## Gaming and power defaults

Raptor leaves Steam's network and shader-cache settings at their defaults and does not force vendor-specific GPU power states through GameMode. Controller access rules remain available. USB autosuspend follows kernel defaults except for device-specific recovery settings.

## Wi-Fi power management

NetworkManager keeps its normal Wi-Fi power-saving and scan-MAC privacy defaults. Raptor Cortex → Settings → Wi-Fi Compatibility provides an opt-in **Disable Wi-Fi power saving** switch for adapters that exhibit reconnect failures or latency spikes with 802.11 power saving. The workaround is not enabled globally because it can reduce laptop battery life. Reconnect to Wi-Fi after changing the setting.

## Steam performance and troubleshooting

GameMode is available when a game requests it natively or is launched with `gamemoderun %command%`. Raptor does not enable GameMode's global GPU performance-level overrides: upstream labels these at-your-own-risk changes, and forcing them across mixed AMD/NVIDIA hardware is not a safe universal default. The system power profile and graphics driver retain control.

- Leave Steam's shader pre-caching at its own default unless troubleshooting a specific issue; disabling it can increase first-run shader compilation stutter.
- If Steam's store/library interface or Big Picture is sluggish while games run normally, try **Steam → Settings → Interface → Enable GPU accelerated rendering in web views**, then restart Steam. Some NVIDIA setups may show menu-rendering artifacts; turn the option back off if they appear.
- Downloads can be limited by CPU decompression, verification, or storage write speed as well as network bandwidth. Check CPU and disk activity before changing network settings.

## System Requirements

| Component | Minimum to install and use | Recommended |
|---|---|---|
| **CPU / architecture** | x86-64 (AMD64/Intel 64); 4 cores, roughly 2 GHz class. Examples: Intel Core i5-8250U (4C/8T) or AMD Ryzen 3 2200G (4C/4T) | 6-core Ryzen 5 3600 / Intel Core i5-10400 class or newer |
| **Memory** | 8 GB RAM | 16 GB+ for gaming, browsers and multitasking |
| **Graphics API** | Working Linux graphics driver with **Vulkan 1.3+** | Modern discrete or integrated GPU with current Mesa / vendor driver |
| **AMD GPU** | Radeon RX 460/560 (Polaris), Vega or newer with `amdgpu` + RADV; older GCN 1/2 needs a recent kernel/driver | Radeon RX 5000-series / RDNA or newer |
| **Intel GPU** | Intel HD Graphics 520, UHD 620/630 or newer when Mesa ANV exposes Vulkan 1.3 | Intel Iris Xe or Arc |
| **NVIDIA GPU** | Pascal-class such as GTX 1060 or newer, with the matching legacy/modern NVIDIA image; Kepler and older are unsupported | Turing (GTX 16 / RTX 20) or newer with the appropriate driver image |
| **Storage** | 50 GB free on an internal SSD; GPT partitioning | 120 GB+ SSD, plus separate space for games and optional apps |
| **Firmware** | UEFI; legacy BIOS/CSM is unsupported | UEFI with Secure Boot configured if desired |
| **Network** | Internet access for installation, updates and optional app downloads | Stable broadband |

**NVIDIA notes:** Bazzite's legacy proprietary-driver image covers Pascal, Maxwell and Volta; its modern open-driver image covers Turing and newer. Kepler and older are not supported by the current proprietary-driver images. Raptor must be built/rebased on the matching NVIDIA base image; the generic image should not be assumed to include every NVIDIA driver.

**Low-memory / Chromebook-class hardware:** Raptor is x86-64 only; ARM Chromebooks are unsupported. The upstream Bazzite gaming baseline is a quad-core 2 GHz CPU and 8 GB RAM, so many entry-level Chromebook processors and 4 GB devices fall below the supported baseline. The 4 GB configuration is an **optimization target under development, not a supported minimum**. Compatible x86-64 Chromebooks still need UEFI, a supported Wi-Fi device and Vulkan 1.3 graphics; compatibility is model-specific and not guaranteed. Vulkan API support alone does not guarantee useful game performance.

Hardware baseline follows [Bazzite's published gaming requirements](https://docs.bazzite.gg/Gaming/Hardware_compatibility_for_gaming/) and [GPU support notes](https://docs.bazzite.gg/General/FAQ/). GPU examples are API-floor examples, not game-performance guarantees: see Intel's [Vulkan support matrix](https://www.intel.com/content/www/us/en/support/articles/000005524/graphics.html), AMD's [Vulkan 1.3 compatibility notes](https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-22-1-2-VULKAN-1-3.html), the [Mesa RADV hardware/API matrix](https://docs.mesa3d.org/drivers/radv.html), and NVIDIA's [Vulkan driver support](https://developer.nvidia.com/vulkan-driver).

---

## Desktop customization

Raptor OS includes an optional **Raptor Flight Deck** panel preset for KDE Plasma 6. Right-click the desktop, choose **Add Panel**, then select **Raptor Flight Deck**. It creates a compact bottom panel with the standard KDE launcher, workspace switcher, running applications, system tray and clock. It does not replace or remove an existing panel; remove the old panel manually after checking the new layout.

Raptor Wallpaper also supports setting the desktop and lock-screen image independently.

## Installation

**Official downloads:** [Raptor OS on Internet Archive](https://archive.org/details/raptor-os_202605). Use an ISO only when the release page lists it with its matching SHA-256 checksum. The image and ISO workflows are separate; CI artifacts are not stable release downloads. The installer leaves disk selection and partitioning interactive and does not automatically erase a drive.

After downloading the ISO, flash it to a USB drive:

- **[Rufus](https://rufus.ie/en/)** — select **DD image mode** + **GPT** partition scheme
- **[Ventoy](https://www.ventoy.net)** — copy ISO to Ventoy USB, boot and select it
- **[Fedora Media Writer](https://github.com/FedoraQt/MediaWriter)** — write the ISO to a USB drive

### Rebase from Bazzite (no reinstall)

```bash
# Step 1 — unverified image to start the transition
rpm-ostree rebase ostree-unverified-registry:ghcr.io/cerberus9-dev/raptor-os:latest
systemctl reboot

# Step 2 — switch to the signed image
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/cerberus9-dev/raptor-os:latest
systemctl reboot
```

> **Already on Raptor OS?** Save your work, then open **Raptor Update Manager** and choose **Update & Reboot**. The update starts immediately, and the system restarts as soon as the new deployment is staged. Flatpak-only updates do not require a reboot.

---

## First Boot

A one-time **Welcome to Raptor OS Home** dialog appears before the browser, chat-client, and optional-app choices:

1. **Browser choice** — no browser ships in the image; Raptor keeps the default *minimal*. Choose Firefox, Brave, Zen Browser, Floorp, Waterfox, Chromium, Chrome, or Edge (each a one-time Flathub download, Firefox pre-selected). Shows a network check, download progress bar, and retry prompt on failure. "Skip — No Browser" installs nothing and forces no default.
2. **Chat client choice** — choose official Discord, Vesktop (Vencord), Equibop (Equicord), or GoofCord. None is pre-installed. "Skip — Install Neither" is always available.
3. **App picker** — around 140 optional entries across 17 categories, covering communication, productivity, privacy, creative work, media, gaming, emulation, education, development, accessibility, and system utilities. Nothing is pre-selected. Reopen **Raptor App Picker** from the application menu to install more software later. "Skip — Install Nothing" is always available.

---

## What's Included

### Pre-installed (always present)

| Category | Apps |
|---|---|
| **Gaming** | Heroic Games Launcher (Epic/GOG/Amazon), ProtonUp-Qt, Protontricks, Wine, Winetricks |
| **Media** | mpv (lightweight playback) |
| **System** | htop, KDE Partition Manager, Plasma System Monitor, Gwenview, KCalc, Fastfetch, p7zip |
| **Raptor Apps** | Raptor Cortex, Raptor Wallpaper, Raptor Update Manager, Raptor Tasks, Raptor Music, and **Raptor Shroudly** — grouped under their own **Raptor OS** category in the app menu |

| **Overlays** | MangoHud (green palette, Shift+F12), Gamemode |

---

### Choose at First Boot

| Category | Apps |
|---|---|
| **Communication** | Telegram, Signal, Element, Discord, Slack, Zoom, Pidgin, Mumble, Jami, Fractal, KDE Connect, Thunderbird, Proton Mail Bridge |
| **Productivity** | LibreOffice, ONLYOFFICE, Planify, Errands, Super Productivity, Joplin, Obsidian, Standard Notes, MarkText, Zotero, Okular, RSS Guard |
| **Passwords & 2FA** | Bitwarden, KeePassXC, Proton Pass, Authenticator |
| **Privacy & Security** | Tor Browser, Mullvad Browser, OnionShare, Proton VPN, Cryptomator, Metadata Cleaner |
| **De-Googled** | LibreWolf, Ungoogled Chromium, FreeTube, Organic Maps, Nextcloud |
| **Graphics** | GIMP, Krita, Inkscape, Darktable, digiKam, Blender, Pinta, Drawing, Upscayl |
| **Screenshots & Capture** | Flameshot |
| **Video & Streaming** | OBS Studio, Kooha, Boatswain, Kdenlive, Shotcut, HandBrake, Parabolic, MakeMKV |
| **Audio & Players** | VLC, Celluloid, Clapper, Strawberry, Amberol, Spotify, Plex, Audacity, LMMS, Ardour, EasyEffects, Helvum |
| **Gaming** | Heroic Games Launcher, Lutris, Bottles, PortProton, Prism Launcher, Sober, QRookie, Cartridges, GOverlay, Moonlight, Sunshine, Chiaki |
| **Emulators** | RetroArch, Dolphin Emulator, PCSX2, DuckStation, RPCS3, Flycast, ScummVM, OpenRA |
| **Devices & Accessibility** | Solaar, Piper, OpenRGB, Speech Note |
| **Torrents** | qBittorrent, Transmission, Fragments |
| **Education & Science** | LabPlot, Cantor, KAlgebra, Kalzium, Step, KStars, Stellarium, Marble, KGeography, KTurtle, Anki |
| **Development** | VSCodium, VSCodium Native, VS Code, IntelliJ IDEA Community, PyCharm Community, GitHub Desktop, Godot Engine, Pods, GitHub CLI, Neovim, C/C++ toolchain |
| **System & Utilities** | LocalSend, Save Desktop, Gear Lever, Resources, Mission Center, Warehouse, Flatseal, BleachBit, Filelight, File Roller, Impression, Deja Dup, Warp, RustDesk, Remmina, GNOME Boxes, btop |
| **Fun & Reading** | Foliate, Calibre, Tuba, Cavalier |

---

## Raptor Cortex

Cortex is organized into Overview, Graphics, Games, Optimize, and Settings tabs. The Graphics tab groups live GPU temperature, model/load/clock/VRAM telemetry, read-only fan sensors, and GPU performance profiles in one place. Unsupported readings are omitted rather than fabricated; fan controls remain with firmware and supported kernel interfaces. Memory compression uses ZRAM with conservative sizing.

**Performance and memory manager**

GTK4/Adwaita app with Power Saving / Balanced / Performance modes. **power-profiles-daemon is the sole owner of CPU governor, boost, EPP, frequency and firmware power policy**, keeping KDE Powerdevil's battery slider functional. Cortex applies separate device-level tuning (such as PCIe/NVMe where supported) and reports failures instead of silently claiming success.

- **Live stats** — RAM, swap, ZRAM, CPU boost, CPU temperature (colour-coded), CPU frequency, memory/swap state, and time since the last optimization run. GPU temperature, adapter model/load/clock/VRAM, and read-only fan RPM/percent sensors live in the Graphics tab when the driver exposes them
- **Optimize Memory Now** — performs bounded, pressure-aware reclaim; it does not indiscriminately flush useful file/game caches
- **Quick Actions** — One-Click Boost (Performance profile, supported GPU profile, optional indexer pause and pressure-aware memory reclaim), Restore Desktop, Clear Shader Cache
- **Persistent Settings** — apply saved mode on every boot, auto-switch to Performance for games launched from the Game Library, auto-restore the previous mode when they exit
- **Scheduled Cleanup** — optional, disabled-by-default pressure-aware memory reclaim on a configurable timer (5–120 min)
- **Game Mode** — pauses optional file indexers, thumbnail work, and KDE crash reporting while a game is active; audio, networking, Bluetooth, package management, storage maintenance, and user applications remain available. Suspended work is restored when Game Mode ends

## GPU profiles

GPU profile selection is part of **Raptor Cortex → Graphics**. The available choices are Auto Detect, Balanced, Max Performance, Extreme, and Power Saving. A selection is applied immediately and saved for the next boot.

## Raptor Tasks

A GTK4/Libadwaita task list with category filters, keyboard shortcuts, an empty-state message, and per-user JSON storage. Saves are atomic so an interrupted write cannot truncate the previous task list; damaged data is preserved for recovery rather than silently discarded.

## Raptor Wallpaper

Wallpaper picker with a thumbnail grid. Select an image to apply it; the gallery includes five Raptor wallpapers and images from your Pictures folder. Fit mode control (Fill/Fit/Stretch/Center/Tile). Right-click any image file in Dolphin → **Set as Raptor Wallpaper** to apply it directly with no window opening. Settings are saved atomically, damaged preferences are preserved for recovery, and inaccessible image folders no longer prevent the rest of the gallery from loading.

## Raptor Music

Raptor Music is being refactored into a wrapper-first application. Raptor owns the unified library, queue, metadata model and playback controls; provider adapters own authentication, search, availability checks and provider-approved playback resolution. The intended primary integrations are Spotify, YouTube and Bandcamp, with local files remaining first-class. A provider may supply a native stream, an embedded player, an external handoff, a preview, or no playback at all; the app must preserve that distinction rather than treating every catalogue result as an audio URL. Existing Audius, Jamendo and Apple Music catalogue paths are optional legacy connectors and are not required by the wrapper architecture. Jamendo is not a core dependency. The audio crate now includes a Spotify Web API search adapter (metadata plus official handoff only), a YouTube Data API search adapter (embedded-player targets only), a limited Bandcamp URL-handoff adapter, and a Rodio backend for authorized HTTPS direct/preview sources. The YouTube embedded-player surface is not yet implemented, Bandcamp search remains unavailable without an authorized API, and the existing Slint screens, queue and desktop provider calls are not yet fully migrated to the normalized model. Rodio copies authorized HTTPS responses to an unnamed temporary file in 64 KiB chunks before decoding. RAM use stays bounded, but playback waits for the download to finish. MusicBrainz is a metadata-only discovery source; it does not provide audio playback. The optional Apple Music connector can provide short previews when a developer token is configured; it does not grant full subscription playback. Raptor Music does not bypass provider subscriptions, ads, DRM or playback restrictions. The database is stored under `$XDG_DATA_HOME/raptor-music/` or `~/.local/share/raptor-music/`.

## Release pipeline (maintainers)

The **Build Raptor OS** workflow publishes the signed OCI image used by existing installations and Raptor Update Manager. It does not create an installer ISO. The separate **Build ISO** workflow uses the published image to create a fresh-install ISO and SHA-256 checksum. Publish both files to the Internet Archive release page before treating the ISO as a public release.

## Discord alternatives

The first-boot chooser offers the official Discord client, Vesktop, Equibop, and GoofCord as optional downloads. Equibop is the Equicord-based Discord desktop client and is available on Flathub as `org.equicord.equibop`. GoofCord is another community Discord client with privacy-focused settings and plugin/theme support.

[Meowcord](https://github.com/meowcorded/meowcord) is also documented as an alternative, but it is **not a desktop Discord client**: it is a self-hosted, federated Discord-like service, currently described by its maintainers as very early alpha. It requires hosting infrastructure and a server instance, so Raptor does not pretend it can be installed as a normal first-boot desktop app. Users can explore or self-host it separately.

## Raptor Shroudly

Raptor OS packages the original Linux **Shroudly** desktop application from the pinned upstream source at [umutxyp/Shroudly](https://github.com/umutxyp/Shroudly). The original Electron/Next.js interface, visual design, Linux networking integration and application behavior are retained; Raptor OS does not replace the upstream UI with a separate dashboard.

The upstream project is copyright **Codeshare Technology Ltd** and is distributed under its MIT license. The upstream source and license remain included in this repository.

When a game requests GameMode, Raptor OS suppresses notification popups and reduces KDE animation duration. The GameMode end hook restores the previous notification state and animation setting. These desktop changes are separate from Shroudly's network-compatibility modes.

---

## Performance

### GPU
- **Auto GPU detection** at boot — AMD, NVIDIA, Intel and hybrid configurations; selects supported GPU environment and driver settings. CPU power policy is handled separately by power-profiles-daemon
- **Cortex telemetry** — reports GPU model, utilization, clock, VRAM, and available fan sensors. Fan readings are read-only; Cortex does not write fan speeds or overclock settings.
- **Shader compilation** — driver and game behavior varies by GPU and Mesa version; no fixed performance improvement is claimed.
- **Mesa GL threading** is enabled for Wine/Proton where supported; native applications keep driver defaults to avoid global compatibility regressions
- **`WINE_FULLSCREEN_FSR` and `DXVK_ASYNC` not set globally** — both caused flickering in OpenGL games (Project Zomboid). Set per-game in Steam launch options instead

### Wine & Windows Apps
- **Normal Wine is the default:** use `wine program.exe`, `winecfg`, `wineboot`, `wineserver`, and `winetricks` as expected. The standard `~/.wine` prefix remains the default; no mandatory profile manager, wizard, storefront setup, or custom prefix workflow is imposed.
- **Simple desktop integration:** opening a Windows executable can launch it with Wine, and MSI installers are passed to `wine msiexec /i`. KDE's context menu offers a direct **Open with Raptor Wine** action.
- **Optional Proton for games:** **Run with Raptor Proton** uses UMU to launch Windows executables with Proton, its game-focused patches, and supported DXVK/VKD3D translation in the Steam Linux Runtime. The Steam client is not required. UMU may download its runtime and Proton components on first use. MSI installers remain on the normal Wine path (`wine msiexec /i installer.msi`); the Proton helper is for executable game launches.
- **Keep the layers separate:** regular desktop applications stay on Wine by default; users choose Proton only when a game or application benefits from it. Existing Wine commands and user-supplied `WINEPREFIX` values remain usable.
- **Useful components included:** Wine Mono, Gecko, and Winetricks are available for common Windows application dependencies. No global DLL overrides or forced esync/fsync settings are applied.
- **Compatibility is program-specific:** anti-cheat, DRM, kernel drivers, unsupported APIs, and application-specific bugs can still prevent software from running. Raptor does not promise universal Windows compatibility.

### File Manager (Dolphin)
- **Default file browser** — Dolphin, not Nautilus (removed). Folders and image types are bound via system-wide `/etc/xdg/mimeapps.list` (+ skel + login migration for existing users)
- **Archive-selection safeguards** — Dolphin's information-panel archive extraction and Baloo content reads are disabled for archive files, and Ark's expensive upstream Compress/Extract plugins are removed to avoid known selection/context-menu stalls. Raptor replaces them with lightweight KIO service menus for **Extract Here**, **Extract To…**, and **Create Archive…**, calling Ark's documented batch interface directly. Double-clicking archives opens Ark; the image includes Ark, 7-Zip and Info-ZIP `unzip`, and common ZIP MIME aliases are routed to Ark to avoid external-open loops. Drag-and-drop extraction remains disabled, and these workarounds do not claim to eliminate every upstream Ark/Dolphin freeze.
- **Preview plugins limited to images + folders** — video/audio/document thumbnail generation could stall selection on large media folders; restricting the enabled thumbnails keeps Dolphin responsive
- **Archive MIME defaults bound to Ark** — double-clicking common ZIP/TAR/7z/RAR formats opens Ark; ZIP MIME aliases are explicitly associated to avoid Dolphin's external-open-as-folder bug

### CPU & Power
- **power-profiles-daemon** owns CPU governor, boost, EPP, frequency limits and supported firmware platform profiles. KDE Powerdevil and Raptor Cortex use this shared interface, so the desktop battery slider remains authoritative
- **Cortex device tuning** is limited to independent controls such as PCIe/NVMe power settings; unsupported hardware is left unchanged
- **Game Mode** avoids repeatedly rewriting CPU policy or performing disruptive memory operations at game launch

### Memory & Low-RAM Tuning
- **ZRAM** — enabled for compressed swap in memory. Capacity and compression behavior are controlled by the image's zram-generator configuration; actual results depend on available RAM, workload, and CPU speed.
- **Baloo** — filename-only indexing with full-text content indexing disabled and a reduced worker count
- **Cortex One-Click Boost** — applies the Performance power profile, pauses configured optional indexers, and requests bounded memory reclaim only under pressure
- Cortex does not flush all caches, change process OOM scores, or force memory compaction as routine optimization.
- **4 GB support remains an unverified optimization target**. Actual idle footprint, browser workload, game performance and sustained memory pressure must be benchmarked on physical low-memory hardware before claiming a 4 GB smooth-use guarantee

### Audio
- **PipeWire 512-sample default quantum** (~10.7 ms) for both the native graph and the `pipewire-pulse` compatibility layer used by Electron/Chromium apps; real-time scheduling is enabled with bounded RT runtime
- **ALSA buffering is device-aware** — built-in outputs use a 512-sample period; USB audio uses a more conservative 1024-sample period and avoids USB autosuspend; the general resampling path uses quality 6 while USB audio retains quality 10 for fidelity
- **Audio devices suspend after 60 seconds idle** rather than being held awake indefinitely; Bluetooth profile switching prefers high-quality A2DP when a headset supports it
- **PipeWire, pipewire-pulse and WirePlumber restart on failure**, with systemd start limits to prevent crash loops

### Network
- **BBR congestion control + CAKE qdisc**, **128 MB TCP buffers**, **socket busy-polling**, **TCP fast-open**
- **Network's own DNS wins, fast DoT resolvers on fallback** — the per-link (DHCP) resolver is always used first (so school/corporate DNS and captive portals work out of the box); Cloudflare/Quad9 DoT are consulted only when a network provides no DNS server. Pinning Cloudflare as the *only* resolver broke DPI'd networks that block `1.1.1.1`
- **Bounded Wi-Fi recovery** — NetworkManager gets time to complete normal association; a watchdog now detects activation states stuck for about three minutes, serializes recovery attempts, bounds CLI calls, and uses a radio reset only after checking for a likely saved network. Automatic driver reloads are avoided because they can disrupt hardware and are reserved for explicit recovery. Resume recovery remains separate and respects the user's Wi-Fi-off choice

### Input
- **Bluetooth recovery** — the resume hook checks the controller and restarts the Bluetooth stack when needed. Other USB devices retain the kernel's normal autosuspend policy.
- **Touchpad recovery** — the resume hook rebinds the touchpad driver when required.
- **Hardware recovery after suspend** (`raptor-hardware-fixes.sh`) — reconnects Wi-Fi and Bluetooth with bounded recovery steps and syncs mute LEDs with audio state.

---

## Window management
Raptor OS runs KDE Plasma on Wayland with KWin. Legacy X11 applications run through XWayland; this is not a separate Xorg session.

- **Window decorations** — Raptor Aurorae theme with Minimize, Maximize, and Close controls on the right and the App Menu on the left
- **Titlebar double-click** — maximizes the window
- **Focus behavior** — click-to-focus
- **Window snapping and tiling** — KWin provides screen-edge snapping/tiling; exact behavior follows the active Plasma/KWin configuration
- **Panel** — KDE Plasma's panel uses the Raptor Flight Deck theme. The optional layout preset is available from Plasma's Add Panel menu.

---

## Built With
- [BlueBuild](https://blue-build.org) — custom OCI image build system
- [Bazzite](https://bazzite.gg) — base image pinned to `stable-44` (Fedora 44), with KDE Plasma 6 on Wayland. The pin is intentional: the moving `stable` tag advanced to Fedora 45, which currently breaks this repository's image-build `rpm-ostree` steps; the Fedora 45 migration remains outstanding.

## Changelog
See [changelog.md](changelog.md) for full version history.
