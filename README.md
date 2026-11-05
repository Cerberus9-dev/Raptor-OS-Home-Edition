# Raptor OS
**Current version: v2.8.0**

A custom Bazzite-based Linux distribution built for gaming — automatic GPU optimisation, low-latency audio, a green accent theme with Windows-style window management, and a zero-terminal firstboot experience.

> **Heavy W.I.P — Feedback appreciated!** This is **not** a live OS. It needs its own drive, replaces your current OS, or runs alongside it as a dual boot. Minimum 40–50 GB free for dual boot. Can be tested in a VM first.

---

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

## Installation

A previously published Raptor OS Home Edition ISO snapshot is available from the [Internet Archive](https://archive.org/details/raptor-os_202605). For a fresh installer matching the current signed image, open **GitHub Actions → Build Raptor OS ISO → Run workflow**. The workflow verifies the image signature, pins its immutable digest, verifies the official Fedora 44 Kinoite installer ISO, injects an interactive Raptor Kickstart with `mkksiso`, and uploads the remastered ISO plus SHA-256 checksum as a 7-day artifact. The installer leaves disk selection and partitioning interactive; it does not automatically erase a drive.

After downloading the ISO, flash it to a USB drive:

- **[Rufus](https://rufus.ie/en/)** — select **DD image mode** + **GPT** partition scheme
- **[Ventoy](https://www.ventoy.net)** — copy ISO to Ventoy USB, boot and select it
- **[Fedora Media Writer](https://github.com/FedoraQt/MediaWriter)** — most reliable, always works

### Rebase from Bazzite (no reinstall)

```bash
# Step 1 — unverified image to start the transition
rpm-ostree rebase ostree-unverified-registry:ghcr.io/cerberus9-dev/raptor-os:latest
systemctl reboot

# Step 2 — switch to the signed image
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/cerberus9-dev/raptor-os:latest
systemctl reboot
```

> **Already on Raptor OS?** Open **Raptor Update Manager** → **Update & Reboot**. Handles system image + Flatpak updates in one click. The app launcher automatically rebuilds its category index after updates so blank folders never appear.

---

## First Boot

Three dialogs appear on the first login, in sequence:

1. **Browser choice** — no browser ships in the image; Raptor keeps the default *minimal*. Choose Firefox, Brave, Chromium, Chrome, or Edge (each a one-time ~100–150 MB Flathub download, Firefox pre-selected). Shows a network check, download progress bar, and retry prompt on failure. "Skip — No Browser" installs nothing and forces no default.
2. **Chat client choice** — Discord (~150 MB) or Vesktop (~100 MB, Vencord built in). Neither is pre-installed. "Skip — Install Neither" is always available.
3. **App picker** — 90+ optional apps across 20 categories, including the GOverlay MangoHud config GUI, game-streaming stack (Moonlight + Sunshine), extra emulators, JetBrains IDEs, and VS Code. Nothing is pre-ticked. Everything here is also installable later from Discover or `flatpak install flathub <id>`. "Skip — Install Nothing" is always available.

---

## What's Included

### Pre-installed (always present)

| Category | Apps |
|---|---|
| **Gaming** | Heroic Games Launcher (Epic/GOG/Amazon), ProtonUp-Qt, Protontricks, Wine, Winetricks |
| **Media** | mpv (lightweight playback) |
| **System** | htop, KDE Partition Manager, Plasma System Monitor, Gwenview, KCalc, Fastfetch, p7zip |
| **Raptor Apps** | Raptor Cortex, Raptor Wallpaper, Raptor Update Manager — grouped under their own **Raptor OS** category in the app menu |
| **One-time integrations** | Raptor Music and Shroudly are included only in the explicitly requested one-time image build; they are not part of normal subsequent rebuilds |
| **Overlays** | MangoHud (green palette, Shift+F12), Gamemode |

---

### Choose at First Boot

| Category | Apps |
|---|---|
| **Browser** | Firefox, Brave, Chromium, Chrome, Edge — all downloads (~100–150 MB), Firefox pre-selected |
| **Chat** | Discord (~150 MB), Vesktop (~100 MB, Vencord built in) |
| **Communication** | Telegram, Signal, Slack, Zoom, Thunderbird, Element (Matrix) |
| **Productivity** | ONLYOFFICE, Bitwarden, Joplin, MarkText, Calibre, Obsidian, Zotero |
| **Office** | LibreOffice |
| **Creative** | GIMP, Inkscape, Krita, Darktable, Blender, Kdenlive, Shotcut, OBS Studio, Audacity, Boatswain, HandBrake |
| **Development** | VSCodium, Developer Runtime (Git + Node.js + pip), Godot Engine, GitHub Desktop, Pods, GCC + Make + CMake, Ninja + Meson, Neovim, GitHub CLI, dash, xclip, ksshaskpass, libssh-tools |
| **Gaming** | Bottles, Lutris, Protontricks, Spotify, Plex, VLC, Cartridges, Ryujinx, RPCS3, RetroArch, Dolphin Emulator, PCSX2, Chiaki, Goverlay |
| **Privacy** | ProtonVPN, KeePassXC |
| **Academic** | Zotero |
| **Remote Access** | RustDesk, Remmina |
| **Media & Downloads** | FreeTube, Parabolic, Kooha, Clapper, Amberol, qBittorrent, Subtitle Edit |
| **Audio Production** | EasyEffects, Helvum, LMMS, Ardour |
| **System** | Warehouse, Impression, CoreCtrl, btop, Variety, Mission Center, Flatseal, BleachBit, Filelight, GNOME Boxes, GNOME Backups, Warp, Flatsweep, Upscayl, Metadata Cleaner, Klipper, kfind, file-roller, Stacer, NCurses Du, Restic |
| **Sync & VPN** | Syncthing, Tailscale |

---

## Raptor Cortex — Performance & Memory Manager

GTK4/Adwaita app with Power Saving / Balanced / Performance modes. **power-profiles-daemon is the sole owner of CPU governor, boost, EPP, frequency and firmware power policy**, keeping KDE Powerdevil's battery slider functional. Cortex applies separate device-level tuning (such as PCIe/NVMe where supported) and reports failures instead of silently claiming success.

- **Live stats** — RAM, swap, ZRAM, CPU boost, CPU/GPU temperature (colour-coded), CPU frequency, and time since the last optimization run
- **Optimize Memory Now** — performs bounded, pressure-aware reclaim; it does not indiscriminately flush useful file/game caches
- **Quick Actions** — One-Click Boost (Performance profile, supported GPU profile, optional indexer pause and pressure-aware memory reclaim), Restore Desktop, Clear Shader Cache
- **Persistent Settings** — apply saved mode on every boot, auto-switch to Performance for games launched from the Game Library, auto-restore the previous mode when they exit
- **Scheduled Cleanup** — optional, disabled-by-default pressure-aware memory reclaim on a configurable timer (5–120 min)
- **Game Mode** — pauses optional file indexers, thumbnail work, and KDE crash reporting while a game is active; audio, networking, Bluetooth, package management, storage maintenance, and user applications remain available. Suspended work is restored when Game Mode ends

## Raptor GPU Profiler

GPU profile selection now lives inside **Raptor Cortex**, under a **Graphics** group. It shipped as its own app for a while, which meant two windows and two launchers for one decision about the same machine; it is now the same row of controls as the CPU boost mode next to it.

- Five profiles — **Auto Detect / Balanced / Max Performance / Extreme / Power Saving** — with a one-line plain-English description of what each actually changes
- Applies immediately, no reboot; the choice survives a reboot because it is stored as a marker file that `gpu-detect.sh` re-reads on every boot
- The `raptor-gpu-profile` package now ships only the detection and apply machinery. If it is not installed, Cortex says so instead of offering buttons that do nothing

## Raptor Wallpaper

Gallery-style wallpaper picker — click any thumbnail to apply it, including four bundled Raptor-branded wallpapers alongside anything in your Pictures folder. Fit mode control (Fill/Fit/Stretch/Center/Tile). Right-click any image file in Dolphin → **Set as Raptor Wallpaper** to apply it directly with no window opening.

## Raptor Music

Native Rust/Slint local music player. Recursively scans folders into a SQLite library, extracts available tags and durations, supports local playlists and queue loading, and plays local audio through a `cpal` backend with pause/resume, previous/next queue controls, and automatic track advance. The scanner recognizes AAC, AIFF, ALAC, CAF, FLAC, M4A, MP3, MP4, Ogg, Opus, and WAV extensions supported by its Symphonia build. The library database is stored under `$XDG_DATA_HOME/raptor-music/` (or `~/.local/share/raptor-music/`). **Image inclusion is opt-in for the single manually dispatched build** using `include_one_time_apps=true`; normal future builds skip it. This is a local-player prototype, not yet the completed independent multi-service music platform described in the project roadmap.

## Raptor Shroudly

**Experimental prototype — not a completed Shroudly port.** The current Rust app is a transitional monitor; it does not provide the original upstream desktop UI, proxy routing, or packet-processing engine. The original Shroudly source is pinned as a submodule and preserved with MIT attribution to **umutxyp / Codeshare Technology Ltd**, but it has not yet been wired into the image. Image inclusion is opt-in for the single manually dispatched build using `include_one_time_apps=true`; normal future builds skip it. Do not configure applications to use this prototype as a proxy.


---

## Performance

### GPU
- **Auto GPU detection** at boot — AMD, NVIDIA, Intel and hybrid configurations; selects supported GPU environment and driver settings. CPU power policy is handled separately by power-profiles-daemon
- **`RADV_PERFTEST=gpl`** — cuts in-game shader compile stalls 30–60% on RDNA2+
- **Mesa GL threading** is enabled for Wine/Proton where supported; native applications keep driver defaults to avoid global compatibility regressions
- **`WINE_FULLSCREEN_FSR` and `DXVK_ASYNC` not set globally** — both caused flickering in OpenGL games (Project Zomboid). Set per-game in Steam launch options instead

### Wine & Windows Apps
- **`raptor-wine` launcher** — `.exe`/`.msi` files are bound to a managed launcher (double-click in Dolphin or right-click → **Run as Windows App**). First launch bootstraps the prefix (`wineboot`) and silently installs the common MSVC++ runtimes + Windows fonts (`vcrun2015`, `vcrun2019`, `corefonts`) — best-effort and retried on flaky networks. `--prefix NAME` for isolated prefixes, `--reset` for a clean slate, `--install-runtime dotnet48` for .NET Framework on demand
- **Session defaults** (`/etc/environment.d/10-raptor-wine.conf`) — `WINEESYNC`/`WINEFSYNC` kernel synchronization (fsync with esync fallback), quiet debug logging (`WINEDEBUG=-all`), `winemenubuilder` disabled so prefixes don't litter the app menu
- **File-descriptor ceiling raised** to 1,048,576 — esync-heavy games and large prefixes no longer hit "eventfd: Too many open files" crashes
- **Wine Mono + Gecko pre-installed** (`wine-mono`, `mingw32/mingw64-wine-gecko`) — .NET and JavaScript-based program loaders/installers work without Wine stalling to download runtimes on first launch
- **ProtonUp-Qt pre-installed** for managing Proton and Wine-GE runners; Bottles, Lutris and more optionally available from the firstboot app picker

### File Manager (Dolphin)
- **Default file browser** — Dolphin, not Nautilus (removed). Folders and image types are bound via system-wide `/etc/xdg/mimeapps.list` (+ skel + login migration for existing users)
- **ZIP/archive freeze & crash defused** — selecting or hovering a .zip used to make the F4 Information Panel parse the file with KFileMetaData in the main process (blocking the UI on big/remote archives and hard-crashing on corrupt ones). The panel is now static by default (`[InformationPanel]` `previewsShown`/`previewsAutoPlay`/`showHovered` all off — F4 still opens it on demand), and Baloo's content indexer is disabled with all archive globs (`*.zip *.tar *.gz *.7z …`) excluded, so bulk-selecting / right-clicking to delete archives never triggers an archive read. Ark's Compress/Extract context-menu plugins (which force a per-file MIME scan on any selection) are also removed at build time — double-clicking a .zip still opens it instantly in Ark. Configs seed new users via skel and correct existing users through a once-per-user login migration
- **Preview plugins limited to images + folders** — video/audio/document thumbnail generation could stall selection on large media folders; restricting the enabled thumbnails keeps Dolphin responsive
- **Archive MIME defaults bound to Ark** — double-clicking a .zip/.tar/.7z/.rar opens it in Ark immediately

### CPU & Power
- **power-profiles-daemon** owns CPU governor, boost, EPP, frequency limits and supported firmware platform profiles. KDE Powerdevil and Raptor Cortex use this shared interface, so the desktop battery slider remains authoritative
- **Cortex device tuning** is limited to independent controls such as PCIe/NVMe power settings; unsupported hardware is left unchanged
- **Game Mode** avoids repeatedly rewriting CPU policy or performing disruptive memory operations at game launch

### Memory & Low-RAM Tuning
- **ZRAM** — LZ4 compression, sized to `min(RAM/2, 8 GB)`, priority 100, `discard` enabled; LZ4 favors lower CPU overhead on older low-power processors
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
- **Forced WiFi reconnection on resume** — NetworkManager dispatcher + resume-trigger service cycle the WiFi interface on wake from suspend (school/corporate APs often drop associations during suspend), and the DNS cache is flushed to clear stale entries from the old network

### Input
- **USB autosuspend disabled** for HID devices and Bluetooth adapters specifically — excluded from Cortex's power-mode switching entirely, so a Bluetooth mouse/keyboard can never be swept into a suspended state by a mode change
- **Stuck-cursor fix after lid close** — udev device re-enumeration and KWin config reload run on resume so the trackpad/pointing device reinitialises cleanly instead of leaving the cursor frozen
- **Hardware recovery after suspend** (`raptor-hardware-fixes.sh`) — re-binds the touchpad driver, reconnects Wi-Fi and Bluetooth with escalating steps, and links the mute LEDs, so nothing comes back from sleep dead

---

## Window Management (KWin on Wayland)
Raptor OS uses KDE Plasma's **KWin** window manager on a **Wayland** session (the documented Bazzite base). The Windows-style description refers to familiar desktop behavior and layout; it does **not** mean Microsoft Windows, and this configuration is not an X11 window manager or an Xlib/XCB-based implementation.

- **Window decorations** — Raptor OS Aurorae decoration with Minimize, Maximize, and Close buttons on the right, plus the App Menu button on the left
- **Titlebar double-click** — maximizes the window
- **Focus behavior** — click-to-focus, matching a familiar desktop workflow
- **Window snapping** — KWin provides screen-edge tiling/snapping; exact behavior depends on the active Plasma/KWin configuration
- **Panel/taskbar** — KDE Plasma's stock panel theme; the Raptor green accent and window decoration are configured separately

---

## Built With
- [BlueBuild](https://blue-build.org) — custom OCI image build system
- [Bazzite](https://bazzite.gg) — base image pinned to `stable-44` (Fedora 44), with KDE Plasma 6 on Wayland. The pin is intentional: the moving `stable` tag advanced to Fedora 45, which currently breaks this repository's image-build `rpm-ostree` steps; the Fedora 45 migration remains outstanding.

## Changelog
See [changelog.md](changelog.md) for full version history.
