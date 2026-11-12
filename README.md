# Raptor OS

**Current stable release:** v2.8.0  
**Next release:** v3.0.0 (in development)

Raptor OS is a Bazzite-based Linux distribution with KDE Plasma, gaming support, and a collection of desktop apps built for the project. The idea is straightforward: make setup, updates and everyday maintenance manageable from the desktop, without taking away the Linux tools that are there when you need them.

> **Work in progress.** v3.0.0 has not been released. Back up important files before installing. Raptor OS can be tested in a virtual machine or installed on a separate drive. Allow at least 50 GB for a dual-boot installation.

## Project goals

- **Desktop-first setup:** updates, app installation, hardware settings, and recovery should be accessible through graphical tools.
- **Keep the base reliable:** use the atomic update model and retain a rollback path. Avoid system-wide tweaks that trade stability for small benchmark gains.
- **Windows app support:** use Wine for ordinary Windows programs and the optional Proton/UMU path for games. Compatibility depends on the application.
- **Hardware support:** test Wi-Fi, Bluetooth, graphics, audio, controllers, sleep and resume on real hardware before describing a fix as complete.
- **Measured performance changes:** make changes only when there is a clear benefit, and avoid disabling services that other desktop or gaming features need.
- **Optional software:** let users choose browsers, chat clients, and other apps instead of installing a large default bundle.
- **Document limitations:** distinguish tested hardware and features from work that is still being developed.

This README describes Home Edition. Security Edition is maintained separately and may have different tools, defaults, and security settings.

### Recovery

Raptor Update Manager can stage a rollback to the previous OSTree deployment when one is available. The user chooses when to restart. A rollback restores the system image, not Flatpak versions, personal files or every setting in the home directory.

### Raptor desktop apps

Raptor Tasks stores tasks locally with search and filters. Raptor Wallpaper provides a searchable gallery and can set the desktop or lock-screen image. Raptor Music keeps local files separate from online discovery and supports in-app playback from Audius and Jamendo. Jamendo uses its free developer API and the track's published Creative Commons license; it does not require a listener subscription. Apple Music provides catalog results and short previews when a developer token is configured. Spotify and Google account connections support metadata import, not in-app streaming.

---

## Gaming and power defaults

Steam's download protocol, shader-cache and storage settings are left entirely at Steam's defaults. GameMode does not force vendor-specific GPU power states globally. Controller access rules remain available, but USB autosuspend is left to the kernel by default to avoid unnecessary idle power draw; device-specific workarounds should be applied only when a reproducible issue calls for them.

## Wi-Fi power management

NetworkManager keeps its normal Wi-Fi power-saving and scan-MAC privacy defaults. Raptor Cortex → Settings → Wi-Fi Compatibility provides an opt-in **Disable Wi-Fi power saving** switch for adapters that exhibit reconnect failures or latency spikes with 802.11 power saving. The workaround is not enabled globally because it can reduce laptop battery life. Reconnect to Wi-Fi after changing the setting.

## Steam performance and troubleshooting

GameMode is available when a game requests it natively or is launched with `gamemoderun %command%`. Raptor does not enable GameMode's global GPU performance-level overrides: upstream labels these at-your-own-risk changes, and forcing them across mixed AMD/NVIDIA hardware is not a safe universal default. The system power profile and graphics driver retain control.

- Leave Steam's shader pre-caching at its own default unless troubleshooting a specific issue; disabling it can increase first-run shader compilation stutter.
- If Steam's store/library interface or Big Picture is sluggish while games themselves run smoothly, check **Steam → Settings → Interface → Enable GPU accelerated rendering in web views**, restart Steam, and compare. Bazzite documents this as a workaround for sluggish Big Picture rendering, but notes that some NVIDIA setups may show menu-rendering artifacts; revert the toggle if that happens.
- Steam downloads can be limited by CPU decompression, verification, and storage write speed—not only network bandwidth. A slow displayed download rate during heavy disk activity does not automatically mean Wi-Fi is broken.
- Raptor leaves Steam's download protocol, connection count, write buffer, and shader-cache settings at Steam's defaults (shader pre-caching remains enabled). Disabling HTTP/2 or increasing connections can help specific network configurations, but these are troubleshooting workarounds—not universal performance defaults. If downloads are slow, compare CPU decompression/verification and disk activity before changing network settings.

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

**Download Raptor OS only from the official [Internet Archive release page](https://archive.org/details/raptor-os_202605).** The page is the public distribution point for the ISO and its matching SHA-256 checksum. End users do not need GitHub Actions access, repository permissions, or CI artifacts. When v3.0.0 (Major Release) is published, its ISO and checksum will be added to that same Archive.org item. The installer leaves disk selection and partitioning interactive; it does not automatically erase a drive.

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

> **Already on Raptor OS?** Open **Raptor Update Manager** and choose **Update & Reboot** to update the system image and Flatpaks.

---

## First Boot

A one-time **Welcome to Raptor OS Home** dialog introduces the Raptor app suite before the three setup dialogs appear:

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

A lightweight GTK4/Libadwaita task list with category filtering, keyboard shortcuts, a helpful empty state, and per-user JSON storage. Saves are atomic so an interrupted write cannot truncate the previous task list; damaged data is preserved for recovery rather than silently discarded.

## Raptor Wallpaper

Gallery-style wallpaper picker — click any thumbnail to apply it, including five bundled Raptor-branded wallpapers alongside anything in your Pictures folder. Fit mode control (Fill/Fit/Stretch/Center/Tile). Right-click any image file in Dolphin → **Set as Raptor Wallpaper** to apply it directly with no window opening. Settings are saved atomically, damaged preferences are preserved for recovery, and inaccessible image folders no longer prevent the rest of the gallery from loading.

## Raptor Music

Native Rust/Slint player for local files, with a SQLite library, playlists and queue management. Online discovery combines public Audius tracks and artist pages, Jamendo's Creative Commons catalogue, Apple Music catalogue results, and MusicBrainz releases. MusicBrainz adds release metadata but no audio. Audius and Jamendo tracks can play in-app; Jamendo playback follows its documented stream endpoint and keeps the published license visible with the track. Jamendo requires a free developer client ID configured as `RAPTOR_JAMENDO_CLIENT_ID`, not a listener subscription. Apple Music results provide short previews unless full playback is authorized through MusicKit. Spotify and Google account connections support metadata import; TIDAL remains an external-service handoff. Raptor Music does not unlock subscription-only catalogues or remove ads from other services. Online results remain separate from the Local Library. The database is stored under `$XDG_DATA_HOME/raptor-music/` or `~/.local/share/raptor-music/`.

## Release pipeline (maintainers)

The **Build Raptor OS** workflow builds and publishes the signed OCI image used by existing installations and Raptor Update Manager. It does **not** create an installer ISO.

The separate **Build ISO** workflow verifies that published image and remasters the Fedora Kinoite installer into a fresh-install ISO with a matching SHA-256 checksum. An image update and an ISO build are intentionally separate operations. The ISO is not considered publicly released until the ISO and checksum are uploaded to the Internet Archive item linked above.

## Discord alternatives

The first-boot chooser offers the official Discord client, Vesktop, Equibop, and GoofCord as optional downloads. Equibop is the Equicord-based Discord desktop client and is available on Flathub as `org.equicord.equibop`. GoofCord is another community Discord client with privacy-focused settings and plugin/theme support.

[Meowcord](https://github.com/meowcorded/meowcord) is also documented as an alternative, but it is **not a desktop Discord client**: it is a self-hosted, federated Discord-like service, currently described by its maintainers as very early alpha. It requires hosting infrastructure and a server instance, so Raptor does not pretend it can be installed as a normal first-boot desktop app. Users can explore or self-host it separately.

## Raptor Shroudly

Raptor Shroudly is the custom native desktop dashboard included in the image. It detects supported game clients and desktop apps; it does not freeze, kill or modify them. Network routing, proxy/tunnel operation and per-app traffic steering are not implemented, so the app does not claim that traffic protection is active. The project is inspired by the original Shroudly project by **umutxyp / Codeshare Technology Ltd**; the upstream desktop app is not bundled.

---

## Performance

### GPU
- **Auto GPU detection** at boot — AMD, NVIDIA, Intel and hybrid configurations; selects supported GPU environment and driver settings. CPU power policy is handled separately by power-profiles-daemon
- **Cortex hardware telemetry** — reports detected GPU model, utilization, active clock and dedicated VRAM where the driver exposes those counters; fan RPM/percentage is read-only and shown only when firmware/driver sensors are available. No unsupported fan-control or overclocking writes are attempted.
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
- **No blanket cache flushes, routine OOM-score changes or forced compaction** as a supposed memory booster
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
- **USB autosuspend disabled** for HID devices and Bluetooth adapters specifically — excluded from Cortex's power-mode switching entirely, so a Bluetooth mouse/keyboard can never be swept into a suspended state by a mode change
- **Stuck-cursor fix after lid close** — udev device re-enumeration and KWin config reload run on resume so the trackpad/pointing device reinitialises cleanly instead of leaving the cursor frozen
- **Hardware recovery after suspend** (`raptor-hardware-fixes.sh`) — re-binds the touchpad driver, reconnects Wi-Fi and Bluetooth with escalating steps, and links the mute LEDs, so nothing comes back from sleep dead

---

## Window Management (KWin, Wayland and X11 application compatibility)
Raptor OS uses KDE Plasma's **KWin** compositor on the Bazzite **Wayland** desktop. **X11 applications are supported through XWayland**; this is X11 compatibility, not Microsoft Windows and not a separate Xorg desktop session. The window decorations and controls provide a familiar desktop workflow without claiming that Raptor OS is Windows.

- **X11 application compatibility** — XWayland runs legacy X11 applications inside the Wayland session
- **Window decorations** — Raptor OS Aurorae decoration with Minimize, Maximize, and Close buttons on the right, plus the App Menu button on the left
- **Titlebar double-click** — maximizes the window
- **Focus behavior** — click-to-focus
- **Window snapping and tiling** — KWin provides screen-edge snapping/tiling; exact behavior follows the active Plasma/KWin configuration
- **Panel/taskbar** — KDE Plasma's panel uses the installed Raptor Flight Deck theme. The optional Raptor Flight Deck layout preset can be added separately from Plasma's Add Panel menu.

---

## Built With
- [BlueBuild](https://blue-build.org) — custom OCI image build system
- [Bazzite](https://bazzite.gg) — base image pinned to `stable-44` (Fedora 44), with KDE Plasma 6 on Wayland. The pin is intentional: the moving `stable` tag advanced to Fedora 45, which currently breaks this repository's image-build `rpm-ostree` steps; the Fedora 45 migration remains outstanding.

## Changelog
See [changelog.md](changelog.md) for full version history.
