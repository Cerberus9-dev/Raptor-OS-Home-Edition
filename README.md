# Raptor OS
**Current stable version: v2.8.0**  
**Next release: v3.0.0 (Major Release) — in preparation**

A custom Bazzite-based Linux distribution built for gaming — automatic GPU optimisation, low-latency audio, an aviation-inspired flight-deck desktop identity, familiar window management, and a zero-terminal first-boot experience.

> **Heavy W.I.P — Feedback appreciated!** This is **not** a live OS. It needs its own drive, replaces your current OS, or runs alongside it as a dual boot. Minimum 40–50 GB free for dual boot. Can be tested in a VM first.

## Raptor OS philosophy

Raptor OS is designed to deliver the reliability and gaming readiness of Bazzite while removing as much everyday Linux friction as practical. Linux is the foundation, not a skill users should have to learn before they can use their computer.

- **GUI-first, terminal-optional:** common setup, updates, app installation, hardware controls, and recovery should be available through clear graphical tools. Terminal commands remain available for advanced users, not required for ordinary use.
- **Stable by default:** preserve the atomic image/update model, keep rollback and recovery paths understandable, and prefer tested defaults over risky performance tweaks.
- **Windows compatibility that feels native:** ordinary Windows applications use familiar Wine behavior; Proton/UMU is an optional game-focused path, not a replacement for Wine or a requirement to use Steam.
- **Hardware should just work:** prioritize dependable Wi-Fi, Bluetooth, audio, graphics, controllers, printers, sleep/resume, and laptop power behavior. Never claim a fix is complete without testing it on real hardware.
- **Performance without placebo tweaks:** optimize only where measurable, keep changes reversible, and never sacrifice core desktop services just to improve a benchmark.
- **No forced ecosystem:** users choose their apps, browsers, chat clients, and workflows. Optional software stays optional, with clear install and removal paths.
- **Honest compatibility and requirements:** document known limitations, distinguish tested support from targets, and do not promise that every Windows program or every low-spec device will work.

These principles apply to both Home Edition and Security Edition. Each edition keeps its own purpose and security posture, but both should feel coherent, approachable, and dependable.

### Recovery and lock-screen customization

Raptor Update Manager exposes the previous OSTree deployment as a guarded rollback action when a previous deployment is available. It stages the rollback and leaves the restart to the user; it does not claim to restore Flatpak versions, personal files, or every user-level setting. The previous deployment remains the recovery target provided by the underlying atomic update system.

Raptor Wallpaper can apply the selected image independently to the desktop or KDE Plasma lock screen. Lock-screen changes are stored in the user's Plasma configuration and take effect the next time the lock screen is shown. The standard KDE Screen Locking settings remain available for timeout, resume-lock, and other security behavior.

### First-party app experience

Raptor Tasks includes category and status filters, live search, task counts, and persistent local task storage. Raptor Wallpaper provides a searchable gallery, a large selected-image preview, display-fit controls, bundled Raptor artwork, and direct application from Dolphin. Both follow the shared aviation-inspired visual system.

### Aviation-inspired visual identity

Raptor OS uses a restrained aerospace / flight-deck visual language across the desktop: deep instrument-panel navy, graphite surfaces, instrument-cyan focus accents, amber caution states, and green operational/success indicators. The Raptor HUD applies the matching KDE, GTK, and Qt/Kvantum styling, with clearer Adwaita cards, navigation surfaces, and status treatments. The aim is a modern aircraft systems aesthetic—not a literal cockpit simulator: keep controls readable, status colors meaningful, animations restrained, and everyday desktop workflows familiar.

---

## Gaming and power defaults

Steam's download protocol, shader-cache and storage settings are left entirely at Steam's defaults. GameMode does not force vendor-specific GPU power states globally. Controller access rules remain available, but USB autosuspend is left to the kernel by default to avoid unnecessary idle power draw; device-specific workarounds should be applied only when a reproducible issue calls for them.

## Wi-Fi power management

NetworkManager keeps its normal Wi-Fi power-saving and scan-MAC privacy defaults. Raptor Cortex → Settings → Wi-Fi Compatibility provides an opt-in **Disable Wi-Fi power saving** switch for adapters that exhibit reconnect failures or latency spikes with 802.11 power saving. The workaround is not enabled globally because it can reduce laptop battery life. Reconnect to Wi-Fi after changing the setting.

## Boot-time behavior

Raptor keeps the GPU profile detection needed before the desktop session, but its hardware probes are bounded so a missing PCI utility or an unresponsive NVIDIA driver cannot hold the display manager indefinitely. Detection reuses one PCI inventory instead of rescanning repeatedly. Power Profiles Daemon is explicitly enabled and remains the single owner of CPU and firmware power policy; obsolete no-op governor and readiness-check units are no longer shipped. Suspend/resume recovery is handled by one systemd-sleep hook that performs touchpad reinitialization and schedules Wi-Fi/Bluetooth recovery after resume. Redundant target-bound sleep units and a marker-only resume service were removed so they cannot add unnecessary work to suspend transitions.

Raptor intentionally does not depend on `systemd-udev-settle.service` for boot ordering. Upstream systemd discourages making the entire boot wait for every device event; device-specific services should wait only for the hardware they actually need.

## Build verification

The image workflow derives the verification tag from the recipe's `image-version` and the event ref, matching BlueBuild's version-suffixed tags (for example, pull-request images use `pr-N-VERSION`). It then pulls that exact image and verifies the installed Raptor Music and Shroudly payloads. The installers also fall back to the build's mounted source-files tree if the temporary staging copy is not visible between BlueBuild modules.

## GPU compatibility defaults

Raptor GPU profiles avoid forcing Mesa driver selection, Vulkan feature levels, or ray-tracing capabilities globally. The graphics stack selects the driver and supported features for the detected hardware. NVIDIA-specific Proton NVAPI integration is emitted only for NVIDIA systems. Shader-cache cleanup remains enabled so caches do not grow without bounds. Performance profiles adjust supported power policy without replacing the graphics driver's compatibility decisions.

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

## Installation

**Download Raptor OS only from the official [Internet Archive release page](https://archive.org/details/raptor-os_202605).** The page is the public distribution point for the ISO and its matching SHA-256 checksum. End users do not need GitHub Actions access, repository permissions, or CI artifacts. When v3.0.0 (Major Release) is published, its ISO and checksum will be added to that same Archive.org item. The installer leaves disk selection and partitioning interactive; it does not automatically erase a drive.

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

A one-time **Welcome to Raptor OS Home** dialog introduces the Raptor app suite before the three setup dialogs appear:

1. **Browser choice** — no browser ships in the image; Raptor keeps the default *minimal*. Choose Firefox, Brave, Zen Browser, Floorp, Waterfox, Chromium, Chrome, or Edge (each a one-time Flathub download, Firefox pre-selected). Shows a network check, download progress bar, and retry prompt on failure. "Skip — No Browser" installs nothing and forces no default.
2. **Chat client choice** — choose official Discord, Vesktop (Vencord), Equibop (Equicord), or GoofCord. None is pre-installed. "Skip — Install Neither" is always available.
3. **App picker** — 90+ optional apps across 21 categories, including Flameshot for screenshot annotation, Save Desktop for desktop backups, KDE Connect, the GOverlay MangoHud config GUI, game-streaming (Moonlight + Sunshine), emulators, IDEs, and more. Nothing is pre-ticked. Search the list by typing, and reopen **Raptor App Picker** from the application menu after first boot to install more software later. "Skip — Install Nothing" is always available.

---

## What's Included

### Pre-installed (always present)

| Category | Apps |
|---|---|
| **Gaming** | Heroic Games Launcher (Epic/GOG/Amazon), ProtonUp-Qt, Protontricks, Wine, Winetricks |
| **Media** | mpv (lightweight playback) |
| **System** | htop, KDE Partition Manager, Plasma System Monitor, Gwenview, KCalc, Fastfetch, p7zip |
| **Raptor Apps** | Raptor Cortex, Raptor Wallpaper, Raptor Update Manager, and Raptor Tasks — grouped under their own **Raptor OS** category in the app menu |
| **Raptor apps** | Raptor Music and the original Shroudly desktop app are built, staged, installed, and verified in every image build |
| **Overlays** | MangoHud (green palette, Shift+F12), Gamemode |

---

### Choose at First Boot

| Category | Apps |
|---|---|
| **Browser** | Firefox, Brave, Zen Browser, Floorp, Waterfox, Chromium, Chrome, Edge — all optional Flathub downloads, Firefox pre-selected |
| **Chat** | Discord, Vesktop (Vencord), Equibop (Equicord), GoofCord — optional Flathub downloads |
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

## Raptor Cortex\n\nCortex is organized into Overview, Graphics, Games, Optimize, and Settings tabs. The Graphics tab groups live GPU temperature, model/load/clock/VRAM telemetry, read-only fan sensors, and GPU performance profiles in one place. Unsupported readings are omitted rather than fabricated; fan controls remain with firmware and supported kernel interfaces. Memory compression uses standard zstd-backed ZRAM by default, with conservative sizing.\n\n — Performance & Memory Manager

GTK4/Adwaita app with Power Saving / Balanced / Performance modes. **power-profiles-daemon is the sole owner of CPU governor, boost, EPP, frequency and firmware power policy**, keeping KDE Powerdevil's battery slider functional. Cortex applies separate device-level tuning (such as PCIe/NVMe where supported) and reports failures instead of silently claiming success.

- **Live stats** — RAM, swap, ZRAM, CPU boost, CPU temperature (colour-coded), CPU frequency, memory/swap state, and time since the last optimization run. GPU temperature, adapter model/load/clock/VRAM, and read-only fan RPM/percent sensors live in the Graphics tab when the driver exposes them
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

## Raptor Tasks

A lightweight GTK4/Libadwaita task list with category filtering, keyboard shortcuts, a helpful empty state, and per-user JSON storage. Saves are atomic so an interrupted write cannot truncate the previous task list; damaged data is preserved for recovery rather than silently discarded.

## Raptor Wallpaper

Gallery-style wallpaper picker — click any thumbnail to apply it, including five bundled Raptor-branded wallpapers alongside anything in your Pictures folder. Fit mode control (Fill/Fit/Stretch/Center/Tile). Right-click any image file in Dolphin → **Set as Raptor Wallpaper** to apply it directly with no window opening. Settings are saved atomically, damaged preferences are preserved for recovery, and inaccessible image folders no longer prevent the rest of the gallery from loading.

## Raptor Music

Native Rust/Slint local music player. Recursively scans folders into a SQLite library, extracts available tags and durations, supports local playlists and queue loading, and plays local audio through a `cpal` backend with pause/resume, previous/next queue controls, and automatic track advance. The scanner recognizes AAC, AIFF, ALAC, CAF, FLAC, M4A, MP3, MP4, Ogg, Opus, and WAV extensions supported by its Symphonia build. The library database is stored under `$XDG_DATA_HOME/raptor-music/` (or `~/.local/share/raptor-music/`). **Built and installed in every image build**; CI compiles and tests the app, stages its executable and verifies the installed application in the resulting image. This is a local-player prototype, not yet the completed independent multi-service music platform described in the project roadmap.

## Release pipeline (maintainers)

The **Build Raptor OS** workflow builds and publishes the signed OCI image used by existing installations and Raptor Update Manager. It does **not** create an installer ISO.

The separate **Build ISO** workflow verifies that published image and remasters the Fedora Kinoite installer into a fresh-install ISO with a matching SHA-256 checksum. An image update and an ISO build are intentionally separate operations. The ISO is not considered publicly released until the ISO and checksum are uploaded to the Internet Archive item linked above.

## Discord alternatives

The first-boot chooser offers the official Discord client, Vesktop, Equibop, and GoofCord as optional downloads. Equibop is the Equicord-based Discord desktop client and is available on Flathub as `org.equicord.equibop`. GoofCord is another community Discord client with privacy-focused settings and plugin/theme support.

[Meowcord](https://github.com/meowcorded/meowcord) is also documented as an alternative, but it is **not a desktop Discord client**: it is a self-hosted, federated Discord-like service, currently described by its maintainers as very early alpha. It requires hosting infrastructure and a server instance, so Raptor does not pretend it can be installed as a normal first-boot desktop app. Users can explore or self-host it separately.

## Raptor Shroudly

**Original upstream application, built into every Raptor OS image.** CI builds the pinned Shroudly Linux desktop app and packages its normal and Advanced-mode engines, desktop entry, icon, and polkit action. It does not enable autostart or change proxy settings during installation; users launch it and choose when to activate protection. The transitional Rust monitor prototype is not packaged. Upstream MIT attribution: **umutxyp / Codeshare Technology Ltd**.


---

## Performance

### GPU
- **Auto GPU detection** at boot — AMD, NVIDIA, Intel and hybrid configurations; selects supported GPU environment and driver settings. CPU power policy is handled separately by power-profiles-daemon
- **Cortex hardware telemetry** — reports detected GPU model, utilization, active clock and dedicated VRAM where the driver exposes those counters; fan RPM/percentage is read-only and shown only when firmware/driver sensors are available. No unsupported fan-control or overclocking writes are attempted.
- **`RADV_PERFTEST=gpl`** — cuts in-game shader compile stalls 30–60% on RDNA2+
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
- **ZRAM** — standard-level zstd compression, logical capacity `min(RAM, 8 GiB)`, priority 100, and `discard` enabled. The configured maximum is virtual capacity, not RAM reserved at boot; physical memory is consumed only as compressed pages are stored. zstd can improve compression ratio versus LZ4 but uses more CPU, so real low-power-device behavior still needs benchmarking. Zswap is not stacked on top of ZRAM: it requires a separate backing swap device and should only be considered when measurements show a benefit.
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
- **Panel/taskbar** — KDE Plasma's stock panel, with the Raptor green accent and window decoration configured separately

---

## Built With
- [BlueBuild](https://blue-build.org) — custom OCI image build system
- [Bazzite](https://bazzite.gg) — base image pinned to `stable-44` (Fedora 44), with KDE Plasma 6 on Wayland. The pin is intentional: the moving `stable` tag advanced to Fedora 45, which currently breaks this repository's image-build `rpm-ostree` steps; the Fedora 45 migration remains outstanding.

## Changelog
See [changelog.md](changelog.md) for full version history.
