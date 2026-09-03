# Raptor OS
**Current version: v2.6.9**

A custom Bazzite-based Linux distribution built for gaming — automatic GPU optimisation, low-latency audio, a green accent theme with Windows-style window management, and a zero-terminal firstboot experience.

> **Heavy W.I.P — Feedback appreciated!** This is **not** a live OS. It needs its own drive, replaces your current OS, or runs alongside it as a dual boot. Minimum 40–50 GB free for dual boot. Can be tested in a VM first.

---

## System Requirements

| | Minimum | Recommended |
|---|---|---|
| **CPU** | 64-bit x86_64, 2 GHz+ quad-core | Recent AMD or Intel processor suited for Linux gaming |
| **RAM** | 8 GB | 16 GB or more for larger games and multitasking |
| **Storage** | ~20 GB (bare-basics default image — no optional apps chosen), SSD required | 50 GB+ if you add creative/dev tools from the optional picker; more for a real Steam library |
| **GPU** | Any GPU supporting Vulkan 1.3+ | AMD or Intel Arc (best-supported); NVIDIA works, with some documented caveats |
| **Boot** | UEFI required, disk must be GPT | — |

---

## Installation

Download the latest Raptor OS Home Edition ISO from Internet Archive [Internet Archive](https://archive.org/details/raptor-os_202605), then flash it to a USB drive:

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

Two dialogs appear on the first login, in sequence:

1. **Browser choice** — Firefox (pre-installed, no download), Brave (~120 MB), or Chrome (~150 MB). Shows a network check, download progress bar, and retry prompt on failure. Closing the dialog keeps Firefox.
2. **App picker** — 65+ optional apps across 12 categories. Nothing is pre-ticked. Everything here is also installable later from Discover or `flatpak install flathub <id>`. "Skip — Install Nothing" is always available.

---

## What's Included

### Pre-installed (always present)

| Category | Apps |
|---|---|
| **Communication** | Vesktop (Discord client — native Wayland) |
| **Browser** | Firefox (memory-optimised: 64 MB cache, 4 processes, tab unloading)|
| **Gaming** | Heroic Games Launcher (Epic/GOG/Amazon), ProtonUp-Qt, Protontricks, Wine, Winetricks |
| **Creative** | Krita (digital painting and illustration) |
| **Media** | mpv (lightweight playback), VLC|
| **Development** | VSCodium, Git, Node.js, Python 3 |
| **System** | htop, KDE Partition Manager, BleachBit, Filelight, Mission Center, Flatseal |
| **Raptor Apps** | Raptor Cortex, Raptor GPU Profiler, Raptor Wallpaper, Raptor Update Manager — all grouped under their own **Raptor OS** category in the app menu |
| **Overlays** | MangoHud (green palette, Shift+F12), GOverlay, Gamemode |

---

### Choose at First Boot

| Category | Apps |
|---|---|
| **Communication** | Telegram, Signal, Slack, Zoom, Thunderbird, Element (Matrix) |
| **Productivity** | ONLYOFFICE, Bitwarden, Joplin, MarkText, Calibre, Obsidian |
| **Office** | LibreOffice |
| **Creative** | GIMP, Inkscape, Darktable, Blender, Kdenlive, Shotcut, OBS Studio, Audacity, Boatswain, HandBrake |
| **Development** | GitHub Desktop, Pods, GCC + Make + CMake, Ninja + Meson, Neovim, GitHub CLI |
| **Gaming** | Bottles, Lutris, Spotify, Plex, Cartridges, Ryujinx, RPCS3, RetroArch, Dolphin Emulator, PCSX2, Chiaki |
| **Privacy** | ProtonVPN, KeePassXC |
| **Media & Downloads** | FreeTube, Parabolic, Kooha, Clapper, Amberol |
| **Audio Production** | EasyEffects, Helvum, LMMS, Ardour |
| **System** | Warehouse, Impression, CoreCtrl, btop, Variety, GNOME Boxes, GNOME Backups, Warp, Flatsweep, Upscayl, Metadata Cleaner |

---

## Raptor Cortex — Performance & Memory Manager

GTK4/Adwaita app with three modes (Power Saving / Balanced / Performance), each applying correctly-differentiated `vm.swappiness` (180/30/5), CPU governor, Energy Performance Preference, CPU max frequency, ACPI platform profile, PCIe ASPM, NVMe power, and audio power settings — switching modes always does a full reset before applying the target mode's settings, so nothing can get stuck half-applied.

- **Live stats** — RAM, swap, ZRAM, CPU boost, CPU/GPU temperature (colour-coded), CPU frequency, and time since the last optimization run
- **Optimize Memory Now** — reclaims real application memory (Firefox/Vesktop heap), not just kernel page cache, via cgroup v2 `memory.reclaim`
- **Quick Actions** — Pre-Game Boost (Performance mode + cache drop in one click), Restore Desktop, Clear Shader Cache
- **Persistent Settings** — apply saved mode on every boot, auto-switch to Performance when a game launches, auto-restore Balanced when it exits
- **Scheduled Cleanup** — optional background optimization on a configurable timer (5–120 min)
- **Game Mode** — suspends 17 background services on game launch (Baloo, Akonadi, KDE Connect, speech-dispatcher, and more), stops `irqbalance`, disables CPU deep sleep for the duration; all resumed automatically on exit

## Raptor GPU Profiler

GTK4/Adwaita graphical profile switcher — GPU info banner (vendor, model, VRAM), five profiles (Auto/Balanced/Performance/Extreme/Power Saving) with a live environment-variable preview, one-click Apply with no reboot required, and a reference panel of useful per-game Steam launch options.

## Raptor Wallpaper

Gallery-style wallpaper picker — click any thumbnail to apply it, including four bundled Raptor-branded wallpapers alongside anything in your Pictures folder. Fit mode control (Fill/Fit/Stretch/Center/Tile). Right-click any image file in Dolphin → **Set as Raptor Wallpaper** to apply it directly with no window opening.

---

## Performance

### GPU
- **Auto GPU detection** at boot — AMD, NVIDIA, Intel, hybrid; sets Vulkan ICD, env vars, shader cache, CPU governor per profile
- **`RADV_PERFTEST=gpl`** — cuts in-game shader compile stalls 30–60% on RDNA2+
- **Mesa GL threading** system-wide via `/etc/drirc.d/` — ~10–20% throughput on CPU-bound OpenGL games
- **`WINE_FULLSCREEN_FSR` and `DXVK_ASYNC` not set globally** — both caused flickering in OpenGL games (Project Zomboid). Set per-game in Steam launch options instead

### CPU & Power
- **Energy Performance Preference** — the single biggest battery saver on modern CPUs (Intel HWP, AMD P-state); cuts package power 20–40% in Power Saving mode vs governor alone
- **CPU max frequency cap** (65% in Power Saving), **ACPI platform profile** coordination (fan curves, VRM limits at the firmware level on supported laptops)
- **`kernel.sched_wakeup_granularity_ns=1000000`** — 1 ms vs kernel default 3 ms, reduces input/frame latency
- **irqbalance** — suspended during game sessions to prevent IRQ reassignment causing frame-time spikes, restarted on exit

### Memory — idle ~2.5–3 GB
- **Akonadi, tracker-miner-fs, plasma-browser-integration masked** by default — none are needed on a gaming system, together save 300–650 MB
- **Baloo: filename-only indexing** — full-text content indexing disabled, 1 thread max
- **ZRAM** — zstd compression, `min(RAM/2, 8 GB)`, priority 100, `discard` enabled
- **`vm.page-cluster=0`**, **`vm.watermark_boost_factor=0`**, **`vm.min_free_kbytes=131072`** — avoids unnecessary decompression, reclaim bursts, and allocation stalls
- **Optimize Memory Now** in Cortex — real app-memory reclaim, not just cache drops

### Audio
- **PipeWire 512-sample quantum** (~10.7 ms) with matching low-latency config for **both** the native graph and the `pipewire-pulse` compatibility layer that Electron/Chromium apps (Discord, Spotify) actually route through — both configured with real-time scheduling
- **`api.alsa.headroom=0`** for outputs — eliminates a 170 ms buffer mismatch that caused crackling
- **Auto-suspend disabled** on all audio devices; PipeWire/WirePlumber/pipewire-pulse all auto-restart on crash with burst-limited retry

### Network
- **BBR congestion control + CAKE qdisc**, **128 MB TCP buffers**, **socket busy-polling**, **TCP fast-open**
- **Cloudflare DoT** — ~10 ms DNS vs ~40–80 ms ISP default
- **DHCP DNS override ignored** — NetworkManager set to `dns=none`, letting systemd-resolved exclusively manage DNS with Cloudflare. Prevents captive-portal or school/corporate networks from pushing broken DNS servers that override the system config

### Input
- **USB autosuspend disabled** for HID devices and Bluetooth adapters specifically — excluded from Cortex's power-mode switching entirely, so a Bluetooth mouse/keyboard can never be swept into a suspended state by a mode change

---

## Window Management (Windows-style)
- **Buttons** — Minimize, Maximize, Close on the right; App Menu on the left
- **Titlebar double-click** — maximises the window
- **Click to raise**, **edge snap** (drag to screen edge to tile)
- Panel/taskbar uses KDE Plasma's own stock theme — green accent colours (buttons, selections, window decoration) still apply throughout, independent of the panel itself

---

## Built With
- [BlueBuild](https://blue-build.org) — custom OCI image build system
- [Bazzite](https://bazzite.gg) — base image (Fedora 42, KDE Plasma 6, Wayland)

## Changelog
See [changelog.md](changelog.md) for full version history.
