# Changelog

## [Unreleased]
- Custom GRUB bootloader theme
- Custom KDE splash screen
- Custom Raptor OS logo
- Custom Icons for all Raptor OS Apps

## [v2.6.9] - 2026-09-03 (DNS Hardening)

### Fixed

- **School/corporate networks pushing broken DNS via DHCP** — when connected to
  networks like school WiFi, the DHCP server provides its own DNS server
  (`10.241.210.1`) which gets applied at the link level in systemd-resolved,
  taking priority over the global Cloudflare DoT config. This caused total DNS
  resolution failure for domains the local DNS couldn't resolve (including
  the school's own OneView portal). Fixed by adding
  `91-raptor-dns.conf` (`dns=none` in NetworkManager) so systemd-resolved
  exclusively manages DNS regardless of what DHCP pushes. Cloudflare DoT
  remains the sole resolver on all networks

### Added

- **`files/system_files/91-raptor-dns.conf`** — NetworkManager config that
  sets `dns=none`, delegating all DNS resolution to systemd-resolved and
  ignoring DHCP-provided DNS servers

## [v2.6.8] - 2026-07-18 (Taskbar Reverted to Stock KDE, Wallpaper App, Service Hardening)

### Removed

- **Custom panel/taskbar theme reverted to stock KDE Breeze Dark** — the
  entire `desktoptheme/RaptorOS` package (`panel-background.svg` and its
  metadata) and the `/etc/xdg/plasmarc` override that forced it system-wide
  have been removed. This ends the multi-version effort (v1 through v9 of
  the panel appletsrc/theme logic) to build a custom nine-slice panel
  background — the underlying rendering issues proved persistent enough
  across different systems that reverting to KDE's own maintained default
  is the more reliable choice. Still applied and unaffected by this change:
  the green colour scheme (button/selection accents), Aurorae window
  decoration (green titlebar accent, Windows-style min/max/close buttons),
  and GTK/Kvantum/Konsole theming — none of that is panel-specific
- **Radar Arc plasmoid removed entirely** — `files/usr/share/plasma/plasmoids/org.raptoros.radararc/`
  (`main.qml`, `main.xml`, `metadata.json`) deleted from the repo. It was
  purpose-built for the now-abandoned custom panel aesthetic, was never
  auto-added to the default layout, and was pure unused maintenance surface
  (QML can break across Plasma major versions) with a non-existent user base
  once opted out
- **Duplicate GPU Profiler removed** — `raptor-hud.sh` contained a complete,
  independent, older bash-TUI GPU profiler (`raptor-gpu-profile-ui.sh` +
  launcher wrapper) that predated the GTK4 rewrite in `raptor-gpu-profile.sh`
  and was never cleaned up. Both wrote a `.desktop` entry named "Raptor GPU
  Profiler" (the visible duplicate in the app menu), and — more seriously —
  both wrote to the *same* destination paths: `/usr/lib/systemd/system/raptor-gpu-profile.service`
  and `/etc/environment.d/raptor-gpu.conf`, with completely different
  content. Whichever script ran last in the build silently won with no
  warning. The old version still had `WINE_FULLSCREEN_FSR=1` set globally —
  the exact setting previously diagnosed and removed for causing Project
  Zomboid flickering — meaning that bug was one `recipe.yml` script reorder
  away from silently returning. Removed all 453 lines of the old
  implementation from `raptor-hud.sh`; the GTK4 version is now the only one

### Fixed

- **`build-iso.yml` failing instantly** — `jasonn3/build-container-installer@v1`
  does not exist; that action has never published a plain `v1` tag, only
  full semver releases. Pinned to `@v1.4.0`, matching what Bazzite itself
  currently uses for the same purpose. Also added `arch: x86_64` explicitly
  to match the action's documented usage
- **Audio static specifically in Spotify and Discord/Vesktop** — both are
  Electron/Chromium-based and route audio through `pipewire-pulse`, a
  separate PulseAudio-compatibility daemon with its own independent config
  and latency properties (`pulse.*` namespaced, not `default.clock.quantum`).
  The existing `99-raptor-pipewire-lowlatency.conf` only tuned the native
  PipeWire graph — `pipewire-pulse` had never been configured at all and was
  running on stock defaults with no RT scheduling, explaining static that
  was specific to Electron/Chromium apps while native clients (games, mpv)
  were already fixed. Added `99-raptor-pipewire-pulse-lowlatency.conf`
  matching request/quantum sizes to the native config and loading the same
  real-time scheduling module. Also gave `pipewire-pulse.service` the same
  crash-loop restart limiting already applied to `pipewire.service` and
  `wireplumber.service`
- **Bluetooth mice/keyboards losing connection after a mode switch or reboot** —
  `_apply_usb_autosuspend()` in Cortex swept every USB device into
  autosuspend with zero exclusions whenever Balanced or Power Saving mode
  applied. An existing udev rule protected `usbhid`-driver devices (wired
  keyboards/mice), but a Bluetooth *adapter* binds to `btusb`, a completely
  different driver — that rule never touched it, and applying autosuspend to
  a Bluetooth adapter is a known way to leave it unresponsive until a manual
  USB reset or reboot. Affects laptops with internal Bluetooth chips too,
  since most enumerate as USB devices despite being built in. Fixed by
  excluding both `btusb` and `usbhid`-bound devices from the sweep in either
  direction (verified against a synthetic sysfs tree before shipping). Added
  a matching persistent udev rule for `btusb` devices, giving Bluetooth
  adapters the same always-on boot-time baseline USB HID devices already had
- **Mangled heredoc delimiter in `raptor-gpu-profile.sh`** — found during a
  full-codebase audit for the same corruption class as the fix below. The
  `/etc/drirc.d/99-raptor-mesa.conf` heredoc delimiter had stray
  quote-escaping artifacts (`<< '"'"'DRIRC'"'"'` instead of `<< 'DRIRC'`)
  left over from an earlier edit, meaning bash was looking for a delimiter
  that could never match the correctly-formed closing line — the Mesa
  GL-threading config write, and everything after it in the script, would
  never have executed
- **`raptor-hud.sh` contained a fully duplicated, truncated copy of itself** —
  found via full-codebase audit: the entire file had been concatenated with
  a second, incomplete copy of itself with no newline separator at the seam.
  `bash -n` caught it as an unterminated heredoc. Truncated back to the
  single complete copy; every other script was checked for the same
  signature and confirmed clean
- **`raptor-cpugovernor.service` and `raptor-ensure-services.service` regressed** —
  both had reverted to pre-fix content (the `PartOf=` coupling bug and
  redundant `gpu-detect.sh` call in cpugovernor; the missing powerprofile
  check in ensure-services) because the corrected versions from earlier in
  development had never actually been uploaded to the repo. Restored both
  fixes as part of this pass
- **Raptor OS never had its own application menu category** — every Raptor
  app's `.desktop` file was tagged `Categories=X-RaptorOS;...`, but that tag
  alone does nothing; KDE only creates a visible menu section for a category
  once it's explicitly registered via a `.directory` file plus a menu XML
  fragment. That registration was never built, so every app was falling
  back into generic System/Settings categories. Added
  `/usr/share/desktop-directories/raptor-os.directory` and
  `/etc/xdg/menus/applications-merged/raptor-os.menu` (the standard
  freedesktop.org mechanism for vendor menu additions), plus a dedicated
  category icon matching the Cortex/GPU Profiler/Wallpaper visual family

### Added

- **Raptor Wallpaper v2.0 — full rewrite, now actually shipping** — the
  previous version was never wired into `recipe.yml`'s build scripts, so it
  had never actually shipped in any build regardless of its own bugs (a
  missing `GdkPixbuf` import, an icon still on the pre-green-conversion blue
  palette, a `.desktop` file pointing at a generic system icon instead of
  its own). Full rewrite: gallery grid (click a thumbnail to apply, replacing
  the old single browse-one-file flow), fit mode control (Fill/Fit/Stretch/Center/Tile
  — the old version had no way to set this at all), four bundled
  Raptor-branded SVG wallpapers (Grid, Radar, Circuit, Horizon, all in the
  HUD green palette), a right-click "Set as Raptor Wallpaper" entry in
  Dolphin for any image file (applies directly, no window opens — mirrors
  behaviour Windows Explorer has had for years), and an icon/`.desktop` pair
  matching the rest of the Raptor app family. Wired into `recipe.yml` for
  the first time
- **Raptor Cortex: Last Optimization timestamp** — new row in the System
  Memory stats panel showing relative time ("Just now", "5 minutes ago", "2
  hours ago", falling back to an absolute date after a week) since the last
  completed optimization run. Tracks all three trigger paths — manual
  "Optimize Memory Now", Pre-Game Boost, and Scheduled Cleanup — since all
  three converge on the same completion handler. Persists across restarts,
  updates live on the existing 2-second refresh timer. The relative-time
  formatter was tested against 16 boundary cases (singular/plural at exact
  1 min/hour/day transitions, the 7-day cutoff to absolute dates, and
  clock-skew handling) before shipping
- **One-time legacy theme migration** — a narrowly-scoped autostart script
  that runs once per user, checks for a stale `name=RaptorOS` line in the
  user's personal `~/.config/plasmarc` (left over from a build prior to the
  panel theme removal above — a system rebuild alone can never reach into an
  already-deployed user's home directory), removes it if found, and
  restarts the panel using the proven safe detached-subshell method (never
  `systemctl restart plasma-plasmashell.service`, which caused a reboot hang
  in a much earlier version)
- **Systemd sandboxing hardening across five `.service` files** — calibrated
  per-service rather than blindly applied: `raptor-ensure-services.service`
  and `raptor-powerprofile.service` are fully hardened (`ProtectSystem=strict`,
  `NoNewPrivileges`, `ProtectKernelTunables`, and more — neither touches the
  filesystem or needs privilege escalation). `raptor-cpugovernor.service` is
  fully hardened except `ProtectKernelTunables`, deliberately omitted since
  the service's entire job is writing to `/sys/devices/system/cpu/*/cpufreq/`.
  `raptor-gpu-profile.service` only gets the hardening that doesn't conflict
  with its real requirements (it calls `sudo -u` internally and writes to
  arbitrary users' home directories, ruling out `NoNewPrivileges` and
  `ProtectHome`). `raptor-firstboot.service` is deliberately left unhardened,
  with the reasoning documented in the file itself — it needs `sudo`, and its
  `/tmp` install logs are meant to stay readable for troubleshooting

## [v2.6.7] - 2026-07-12 (Power Saving Overhaul, RAM Reduction, Cortex Expansion)

### Fixed

- **App launcher blank categories / scrolls to Favourites after updates** —
  the sycoca rebuild autostart was running `kbuildsycoca6 --noincremental`
  unconditionally on every login, which doesn't delete the stale cache files.
  After an OSTree update the cache was built against the old deployment's file
  paths and inode numbers; Plasma read the stale cache before the rebuild
  finished, producing blank category pages. Fixed with a deployment-aware
  script at `/usr/lib/raptor/sycoca-rebuild.sh`: reads the current OSTree
  deployment checksum via `rpm-ostree status --json` and compares it against
  `~/.cache/raptor-deploy-hash`. If the deployment changed (i.e. an update
  was applied), all `ksycoca6_*` files are deleted before the rebuild so it
  starts completely clean. Normal logins (same deployment) do a fast
  incremental check only. The Raptor Update Manager also wipes the cache
  and the hash file before triggering a reboot, so the post-update login
  always gets a clean rebuild

- **`build.yml` failing on every push** — `actions/checkout@v7` does not
  exist (latest major version is v4). Every push to main was failing at the
  checkout step before a single build step ran. Fixed to `@v4`

- **`raptor-audio-rt.conf` security issue** — `*  -  rtprio  10` granted
  real-time scheduling to every user account on the system. Changed to scope
  only to the `@audio` group (`@audio  -  rtprio  95  /  memlock unlimited`)
  which is what PipeWire and JACK actually need

- **`raptor-cpugovernor.service` calling gpu-detect.sh redundantly** —
  `ExecStart=/usr/lib/raptor/gpu-detect.sh` was called from the CPU governor
  service, running the entire GPU detection + env propagation + sysctl reload
  pipeline a second time at every boot. Also had `PartOf=raptor-gpu-profile.service`
  which incorrectly coupled the two service lifecycles. Replaced with a minimal
  inline script that only writes the CPU governor

- **`raptor-ensure-services.service` not checking power profile** — only
  checked `raptor-gpu-profile.service`; if `raptor-powerprofile.service` failed
  at boot nothing noticed. Added to the health-check loop

- **`cosign.yml` losing `cosign.pub`** — the previous workflow uploaded the
  public key as a 90-day GitHub artifact which expired and deleted it. The
  public key needs to be permanently in the repository root for image
  verification. Rewritten to auto-commit `cosign.pub` to the repo via
  `git push` after generation; the private key is uploaded as a 1-day artifact
  with explicit instructions to add it as `SIGNING_SECRET` then delete it

- **PipeWire/WirePlumber crash loops** — `Restart=on-failure` with no rate
  limiting caused infinite restart loops if a bad plugin caused immediate
  re-crash on every start. Added `RestartLimitBurst=5 / RestartLimitIntervalSec=60`

- **Outdated Brave `--enable-features` flags** — `CanvasOopRasterization`
  (removed ~Chromium v112), `OverlayScrollbar` (removed ~v108), and
  `LightweightNoStatePrefetch` (deprecated ~v116) were generating silent
  warnings. Removed all three

### Added

#### Power Saving — major overhaul

- **Energy Performance Preference (EPP)** — new `_apply_epp()` helper writes
  to `/sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference`
  and the legacy `energy_perf_bias` register. Setting `EPP=power` in Power
  Saving mode tells the CPU hardware P-state controller (Intel HWP, AMD
  P-state) to strongly favour efficiency; this is the single biggest battery
  saver on modern CPUs, cutting CPU package power by 20–40% vs using the
  `powersave` governor alone without EPP. EPP is restored to `balance_power`
  (Balanced) and `performance` (Performance) when switching modes

- **CPU max frequency cap** — new `_apply_cpu_max_freq_pct()` helper caps
  `scaling_max_freq` to 65% of `cpuinfo_max_freq` in Power Saving mode.
  On a 5 GHz CPU this prevents any burst above ~3.25 GHz, eliminating the
  power spikes from turbo frequency. Restored to 100% on mode change

- **Platform profile** — new `_apply_platform_profile()` helper writes to
  `/sys/firmware/acpi/platform_profile` (`low-power` / `balanced` /
  `performance`). On supported laptops (ThinkPad, ASUS, Dell, HP) this is a
  firmware-level ACPI call that coordinates fan curves, VRM power limits, and
  thermal targets at the EC level — often more effective than any Linux
  software tuning. No-ops silently on unsupported hardware

- **Network device runtime PM** — new `_apply_net_runtime_pm()` enables
  `auto` power management for all network hardware. The NIC hardware powers
  down between packets without disconnecting WiFi or Bluetooth. Restored to
  `on` in Balanced/Performance modes

- **HDA audio powersave controller** — `power_save_controller=Y` written to
  `/sys/module/snd_hda_intel/parameters/power_save_controller` in Power Saving
  mode. This allows the HDA controller itself (the PCI device, not just the
  codec) to power off when idle — saves an additional 0.5–1 W beyond the
  existing `power_save=1` codec setting

- **More aggressive disk write-back** — `vm.dirty_writeback_centisecs=15000`
  (150 s) in Power Saving mode (was 6000). Storage controllers go into deep
  low-power states between access events; longer intervals mean more time in
  deep sleep. `vm.laptop_mode=5` (was 1)

- **GPU profiler powersave: 4 new controls** — AMD: `pp_power_profile_mode=1`
  (video profile — lower, sequential clock pattern), GFXOFF enabled via
  `/sys/kernel/debug/dri/*/amdgpu_gfxoff` (shader engine fully powers off at
  idle, saves 0.5–2 W on RDNA2+). Intel: `i915.enable_psr=1` (Panel
  Self-Refresh — display controller stops driving the eDP panel between frame
  updates, saves 0.5–1.5 W). NVIDIA: power limit reduced to 80% of TDP via
  `nvidia-smi -pl`

- **PowerDevil battery profiles** — written to `/etc/skel/.config/powermanagementprofilesrc`
  so all new users get KDE screen dim and auto-suspend configured from first
  login. Previously KDE's defaults were `turnOffDisplayWhenIdle=false` and
  `idleTime=0` on all profiles (screen never dims, never suspends on battery).
  Now: AC dims after 5 min / off after 10 min; Battery dims after 60 s /
  off after 2 min at 70% brightness / suspends after 10 min; Low Battery
  dims after 30 s / 30% brightness / suspends after 5 min with hibernate

#### Raptor Cortex — expanded features

- **Temperature monitoring** — CPU temperature, GPU temperature, and CPU
  frequency rows added to the System Memory stats panel. Temperature labels
  are colour-coded: orange warning at 75°C CPU / 80°C GPU, red error at
  90°C / 95°C. CPU temp reads `x86_pkg_temp` / `k10temp` from thermal zones;
  GPU reads AMD hwmon or falls back to `nvidia-smi`; frequency reads
  `scaling_cur_freq`

- **Quick Actions** — three one-click presets:
  - *Pre-Game Boost*: switches to Performance + runs enabled optimize options
  - *Restore Desktop*: switches to Balanced + resumes all suspended services
  - *Clear Shader Cache*: deletes Mesa, RADV, AMDVLK, and Steam shader caches;
    reports MB freed

- **Persistent Settings** — three toggles written to
  `~/.config/raptor-cortex-settings.json` that survive reboots:
  *Apply selected mode on boot*, *Auto-switch to Performance when game starts*,
  *Restore Balanced mode after game exits*

- **Scheduled memory cleanup** — configurable GLib timer (5–120 min, default
  30 min) that automatically runs the enabled optimization options in the
  background. Never auto-runs Swap Pressure Flush or Deep Clean. Shows next
  scheduled time in the UI. Persists across launches

#### Raptor GPU Profiler — full GTK4/Adwaita rewrite

- Replaced the bash TUI with a proper GTK4/Adwaita graphical app installed at
  `/usr/bin/raptor-gpu-profiler`. Matches Cortex's visual style exactly:
  `Adw.ApplicationWindow`, `Adw.PreferencesGroup`, `Adw.ActionRow`, toast
  notifications, pill buttons. Features: GPU info banner (vendor, model, VRAM),
  profile selector (Auto/Balanced/Performance/Extreme/Power Saving) with live
  environment variable preview, Apply button that writes flag files and re-runs
  `gpu-detect.sh` without requiring a reboot, per-game Steam launch option
  reference panel

#### Memory — idle ~2.5–3 GB (was ~3.5 GB)

- **Akonadi masked** — KDE PIM database server disabled by default via
  `/dev/null` symlinks in `/etc/systemd/user/`. Saves 200–500 MB at idle
  (re-enable: `systemctl --user unmask akonadiserver.service`)
- **tracker-miner-fs-3 masked** — GNOME file indexer redundant alongside KDE
  Baloo. Saves ~60–100 MB
- **plasma-browser-integration masked** — browser tab sync service disabled
  by default. Saves ~80 MB
- **Baloo: filename-only indexing** — disabled full-text content indexing in
  system-wide `/etc/xdg/baloofilerc`; 1-thread maximum. Sufficient for search,
  fraction of the RAM and CPU cost
- **`HiddenPreviews=4`** (was 5) — no longer keeps textures for minimised
  windows in memory. Value 5 was holding up to 300 MB of window thumbnails
  in RAM on sessions with many open windows
- **`vm.page-cluster=0`** — single-page reads from ZRAM (avoids decompressing
  8 pages when only 1 was requested)
- **`vm.compaction_proactiveness=20`** — background memory defragmentation
  to avoid stall-inducing compaction bursts

#### MangoHud and Gamemode

- MangoHud: added `gpu_junction_temp`, `cpu_power`, `io_read/write`,
  `histogram`, `vulkan_driver`, `kernel`, `os`, `arch`; added logging via
  `toggle_logging=Shift_R+F2` writing to `~/mangohud_logs/`; GPU colour
  updated to `#33FF33` to match new green HUD palette; `fps_limit_method=early`
- gamemode.ini: added `nv_powermizer_mode=1` for NVIDIA persistence, added
  `gamescope` to supervisor whitelist, added `[script]` section

#### HUD theme — full green colour overhaul (stamp v9)

- All accent colours changed from dodger blue (`#1e90ff` / `30,144,255`) to
  neon green (`#33FF33` / `51,255,51`) across 54 locations: colour scheme,
  GTK CSS, Konsole profile, Aurorae window decoration, radar arc plasmoid
- `panel-background.svg` rewritten with correct nine-slice element IDs
  (`topleft`, `top`, `topright`, `left`, `center`, `right`, `bottomleft`,
  `bottom`, `bottomright`) and proper neon green glow gradient. Previous version
  was missing the nine-slice IDs entirely, causing Plasma to stretch the SVG
  rather than slicing it correctly
- `/etc/xdg/kwinrc` written at build time with `LatencyPolicy=0` and
  `HiddenPreviews=4`; `FocusPolicy=ClickToFocus` for Windows-like focus

### Changed

- `zram-generator.conf`: added `options = discard` (freed compressed pages
  returned to ZRAM pool immediately rather than holding dead slots)
- Browser firstboot dialog: added Google Chrome as a third option
  (`com.google.Chrome`) with network check, download progress bar, and retry
  prompt on failure
- Recipe: Krita added as default RPM; VSCodium and VLC added to default
  Flatpaks; gcc/make/cmake moved to optional picker; Akonadi/tracker/
  plasma-browser-integration masked at build time
- `raptor-gpu-profile.sh`: added `RADV_PERFTEST=gpl` globally (cuts
  in-game shader compile stalls 30–60% on RDNA2+); added
  `/etc/drirc.d/99-raptor-mesa.conf` enabling `mesa_glthread=true`
  system-wide; fixed `ExecStart` path in `raptor-gpu-profile.service`
  (was `/usr/bin/raptor-gpu-profile.sh`, should be `/usr/lib/raptor/gpu-detect.sh`)

## [v2.6.6] - 2026-06-23 (Launcher Fix, Window Buttons, Firstboot Polish)

### Fixed

- **Application launcher blank category tabs** — `raptor-gaming.sh` was calling
  `kbuildsycoca6 --invalidate` at container build time. `--invalidate` deletes
  the sycoca service cache entirely, so the final image shipped with no cache.
  On first login Plasma tried to rebuild it but the app launcher rendered before
  the build completed, showing empty category pages. Removed the `--invalidate`
  call and added an XDG autostart `.desktop` entry that runs
  `kbuildsycoca6 --noincremental` with `X-KDE-autostart-phase=1` (before the
  shell finishes loading) so the cache is always valid by the time the launcher
  is first opened

- **Window minimize/maximize/close buttons not applying** — `ButtonsOnLeft=M` /
  `ButtonsOnRight=IAX` were written by the user service which fires after KWin
  has already read its config. Added `/etc/xdg/kwinrc` written at build time
  with the same button layout, matching the `/etc/xdg/plasmarc` fix from v2.6.4.
  Window buttons (Minimize, Maximize, Close on the right; App Menu on the left)
  are now applied from the very first login

- **Browser firstboot dialog re-appears every session** — "Decide Later" button
  did not write the stamp file, causing the dialog to re-appear on every login
  until an explicit choice was made. Renamed to "Keep Firefox" and now writes the
  stamp on dismiss, treating closure as "I want Firefox"

- **Internet Archive ISO upload failing** — `ia configure --username="" --password=""`
  was passing empty strings to the IA configurator, which created a corrupt
  config file and caused authentication failures. IA S3-style uploads only need
  the access key and secret key. Rewrote the config step to write
  `~/.config/internetarchive/ia.ini` directly. Added `--checksum` (skip re-upload
  of identical files, enabling safe re-runs), `--retries 10` (automatic retry for
  large file chunks over flaky connections), `--no-derive` (skip IA's derivative
  generation which is unnecessary for binary ISOs), and explicit `--remote-name`
  to control the filename on IA regardless of the local build path. SHA256
  checksum is now uploaded alongside the ISO automatically

### Added

- **More optional apps in firstboot picker**:
  - *Privacy*: ProtonVPN, KeePassXC (offline password manager)
  - *Entertainment*: FreeTube (ad-free YouTube client), Obsidian (linked markdown notes)
  - *Gaming*: Cartridges (unified game library), Ryujinx (Switch emulator), RPCS3 (PS3 emulator)
  - *Audio production*: Helvum (PipeWire patchbay), LMMS (music production), Ardour (DAW)

## [v2.6.5] - 2026-06-19 (Theme Fix, Mode Profile Corrections, Network Tuning)

### Fixed

- **HUD theme still not applying — root cause found** — Plasma 6 uses KPackage
  format and discovers themes via `metadata.json`. The RaptorOS theme only had
  `metadata.desktop` (Plasma 5 format). Without `metadata.json`, Plasma 6 cannot
  locate the theme by its ID string in its package index — `kwriteconfig6` writes
  `RaptorOS` to `plasmarc` but Plasma sees no theme with that ID and silently
  falls back to Breeze Dark. This is almost certainly the primary reason the HUD
  theme never applied in v1–v6 on Plasma 6 builds. Added `metadata.json` with
  `"Id": "RaptorOS"` and `"X-Plasma-API-Minimum-Version": "6.0"`. Stamp bumped
  to v7 so the theme service re-runs on all existing installs

- **Performance mode `vm.swappiness = 60`** — was set to the same value as
  power saving mode, actively working against gaming. The system-level baseline
  is `swappiness=10`; performance mode was raising it to 60, telling the kernel
  to eagerly swap game data out to ZRAM. Fixed to `swappiness=5` (strongly prefer
  keeping all anonymous memory in RAM)

- **Balanced mode `vm.swappiness = 100`** — at 100 the kernel treats file cache
  and anonymous memory (game/app heap) equally for eviction, swapping out
  application data as aggressively as stale file buffers. Fixed to `30` (lean
  toward RAM retention while still allowing relief under pressure)

- **Performance mode dirty ratios** — `dirty_ratio=10` caused write stalls at
  only 10% of RAM dirty (1.6 GB on 16 GB). Games write saves and logs rarely
  but in bursts; a stall at 1.6 GB interrupts gameplay. Raised to `25/10`
  (background flush at 10%, stall threshold at 25%)

- **`kbuildsycoca6 --invalidate` in game mode entry** — `--invalidate` forces a
  full sycoca rebuild from scratch, taking 2–5 seconds right when the user is
  launching a game. Removed from `trim-background`

### Added

- `net.core.busy_read = 50` and `net.core.busy_poll = 50` to the network sysctl
  — socket busy-polling spins for up to 50 µs before sleeping when waiting for
  incoming data, eliminating the syscall/wakeup round-trip for low-latency UDP
  game traffic (position updates, voice chat). Only active on sockets that
  explicitly opt in via `SO_BUSY_POLL`

- `fs.file-max = 2097152` — raises the system-wide open file descriptor limit
  from the default 1 M. Open-world games and heavily modded titles (Skyrim,
  Minecraft with large mod packs) can exhaust the default limit on startup

## [v2.6.4] - 2026-06-19 (Boot Stability, Final HUD Fix & Smaller Install)

### Fixed

- **Taskbar still broken (v6 HUD rewrite)** — All versions v1–v5 of
  `apply-plasma-panel.sh` had variations of the same fundamental mistake:
  writing to `plasma-org.kde.plasma.desktop-appletsrc`. This caused the
  wallpaper, pinned apps, and panel widget positions to reset on every stamp
  bump, and introduced complex "read-and-restore" logic that kept breaking in
  new ways. The fix: v6 is theme-only. The F-22 HUD visual appearance (dark
  panel, neon green glow) comes entirely from the `RaptorOS` Plasma theme SVGs
  — the panel structure (appletsrc) is irrelevant. v6 applies only: colour
  scheme, `plasmarc Theme name`, icons, window decoration, Kvantum, GTK
  settings. Never touches the appletsrc. Never writes a wallpaper path. Never
  clears launchers. The service also verifies the RaptorOS theme directory
  exists before writing to plasmarc — previously, if the theme was missing for
  any reason, plasmarc pointed at a non-existent theme and Plasma silently fell
  back to Breeze Dark with no error

- **Wallpaper resets to Bazzite default** — caused by appletsrc writes in v1–v5
  (see above). Fixed by v6: no appletsrc writes at all

- **Pinned apps cleared / moved** — same root cause. Fixed by v6

- **Boot stuck / struggles to autoboot** — `raptor-powerprofile.service` had
  `Requires=power-profiles-daemon.service` (hard dependency). If
  `power-profiles-daemon` was slow to start or briefly failed at boot, systemd
  waited up to 90 s before marking the dependency failed, stalling the entire
  `multi-user.target`. Changed to `Wants=` (soft dependency): if
  `power-profiles-daemon` isn't ready, the service still runs and the
  `|| true` on its ExecStart handles the `powerprofilesctl` failure gracefully

### Changed

- **Smaller default install** — removed from the mandatory RPM list:
  `neovim` (terminal text editor), `tmux` (terminal multiplexer),
  `ripgrep`/`fzf` (developer search tools), `ninja-build`/`meson`
  (build systems), `podman`/`podman-compose` (container tools),
  `thunderbird` (email — most users use browser), `variety` (wallpaper
  manager), `btop` (redundant with `htop` and Mission Center Flatpak).
  `Thunderbird` is now in the firstboot optional picker as a Flatpak.
  `gcc`, `make`, and `cmake` are retained (useful for game mod compilation)

- **Additional memory tuning** — `vm.watermark_boost_factor = 0` added to the
  system sysctl: the default of 250% causes sudden large memory-reclaim bursts
  that manifest as frametime spikes during gaming. Disabled in favour of
  gradual reclaim. `kernel.sched_autogroup_enabled = 1` groups related
  processes (game + its threads) as a scheduling unit, improving responsiveness
  of the foreground game relative to background daemons

## [v2.6.3] - 2026-06-18 (Audio Static, Taskbar & Wallpaper Fixes)

### Fixed

- **Audio static / crackling** — `api.alsa.headroom = 8192` for outputs was
  the cause. Headroom is extra ALSA buffer samples beyond the quantum that the
  driver keeps buffered; at 8192 samples that's 170 ms of additional buffer
  which created a fundamental timing conflict with the 256-sample (5.3 ms)
  quantum. PipeWire's graph thread tried to produce audio in 5.3 ms bursts
  while ALSA's driver expected 170 ms fill cycles — the mismatch caused
  mid-period starvation and the characteristic pop/click/static. Fixed:
  `api.alsa.headroom = 0` for outputs (PipeWire manages its own timing),
  quantum raised from 256 → 512 samples (10.7 ms, still excellent for gaming,
  resilient to CPU spikes during heavy GPU frames), ALSA period size raised to
  match. Mic inputs keep a small 512-sample headroom since capture timing is
  less deterministic

- **Wallpaper reset to CachyOS/Bazzite default on boot** — the appletsrc
  written by `apply-plasma-panel.sh` included `[Containments][1]` (the Desktop
  containment) with `FillMode=2` but no `Image=` path, so Plasma substituted
  the distro default wallpaper. Fixed: the script now reads the current
  wallpaper path from the existing appletsrc before overwriting and appends it
  back into the new file after the write

- **Pinned taskbar apps cleared on each update** — every stamp bump re-ran the
  service, deleted the appletsrc, and wrote a fresh one with `launchers=` empty,
  clearing all pinned apps. Fixed with a two-phase approach: the panel layout
  (appletsrc) now only writes once per install, guarded by a `[RaptorOS]`
  section marker. The script reads and restores the existing `launchers=` value
  before overwriting. Future stamp bumps (v6, v7…) only re-apply the theme —
  the layout, pinned apps, wallpaper, and widget positions are never touched
  again unless the user deletes the `[RaptorOS]` section

- **Machine stuck on reboot / required hard power-off** — `apply-plasma-panel.sh`
  was calling `systemctl --user restart plasma-plasmashell.service` from inside
  another user service (`raptor-hud-apply.service`). `plasma-plasmashell.service`
  is `PartOf=graphical-session.target` — restarting it via systemd mid-session
  signalled to systemd that the graphical session target was cycling, which
  triggered a shutdown dependency cascade before the system was ready to reboot,
  leaving the bootloader in a retry loop. Fixed: plasmashell restart now uses a
  detached background subshell with a 5-second delay. The service exits cleanly
  (stamp written), then 5 seconds later the subshell runs `killall plasmashell`
  + `plasmashell --replace` with no systemd involvement at all

- **Taskbar theme still not applying** — the session environment variables
  (`DBUS_SESSION_BUS_ADDRESS`, `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`) were not
  reliably inherited by the systemd user service. Now set explicitly at the
  start of the script using the known standard paths as fallback values

## [v2.6.2] - 2026-06-13 (Taskbar Stability, Real Memory Reclaim & Smaller Install)

### Fixed

- **"Optimize Memory Now" crashed the taskbar** — the optimize routine sent
  `SIGUSR1` to `plasmashell` and `kded6` as part of a (non-functional) memory-trim
  signal. Neither process installs a SIGUSR1 handler, so the kernel's default
  action — terminate — applied. Killing `plasmashell` is killing the panel; systemd
  restarted it immediately, which looked like the taskbar vanishing and reappearing.
  The entire signal-based mechanism has been removed

- **Panel layout still broken after the v2 HUD rewrite** — the v2 `appletsrc`
  defined only a Panel containment with no Desktop containment, and included two
  `org.raptoros.radararc` applets (custom Canvas/QML). If that plasmoid hit any
  QML error on load, Plasma 6 could abort loading the rest of the containment's
  applets or fall back to a default layout — taking the whole panel with it.
  Rewrote `appletsrc` (now v3) with a complete Desktop containment alongside the
  Panel, and removed the radar arc applets from the auto-generated layout. The
  panel now uses only stock, known-good KDE applets: launcher, task manager,
  system tray, clock, show desktop

- **`partitionmanager` package not found** — Fedora's package providing the
  `partitionmanager` binary is named `kde-partitionmanager`; corrected in
  `recipe.yml`

- **Firefox memory policy silently ignored on existing profiles** — the
  `policies.json` written in v2.6 used `"Status": "default"`, which only applies
  if the user has no existing value for that preference. Any profile that wasn't
  brand new already had its own `browser.cache.memory.capacity` etc., so the
  64 MB cap, process-count reduction, and tab-unloading were never actually
  applied. Changed all ten memory-related policies to `"Status": "user"`, which
  writes the value directly into the profile, overriding whatever was there

- **Changelog structure** — a previous edit dropped the `## [v2.6]` version
  header while inserting `v2.6.1` above it, leaving v2.6's entire feature list
  (300+ lines) orphaned under the v2.6.1 heading with a duplicate `### Fixed`.
  Header restored

### Added

- **Real memory reclaim via cgroup v2** — `drop_caches` only affects kernel-internal
  page/dentry/inode caches, which are often small on a normal desktop. The bulk of
  "used" RAM is anonymous memory held by running apps (Firefox, Vesktop, Steam).
  Added `_reclaim_user_slice()`, which writes to
  `/sys/fs/cgroup/user.slice/memory.reclaim` (cgroup v2, kernel 5.10+) — this walks
  the LRU of every process under `user.slice` and writes back/drops/swaps-to-zram
  whatever's reclaimable, scoped to user processes only (never the root cgroup).
  Wired into "Drop caches" (1 GiB request), "Deep Clean" (3 GiB), and game-mode
  entry via `trim-background` (1.5 GiB) — the "Freed XXX MB" number in Cortex now
  reflects real memory given back by background apps, not just kernel cache trivia

- **`vm.min_free_kbytes = 131072`** — added to the baseline sysctl. The kernel
  default (often 4–16 MB on desktop) is thin for the large, bursty allocations
  games make; a bigger free-page reserve avoids synchronous-reclaim stalls at
  allocation time

- **journald RAM caps** — `/etc/systemd/journald.conf.d/raptor-memory.conf` limits
  the runtime journal (tmpfs-backed, i.e. RAM) to 64 MB and the persistent on-disk
  journal to 200 MB; default limits scale with disk size and can otherwise reach
  several hundred MB in the runtime journal alone

- **`ModemManager.service` masked** — probes for cellular hardware on every boot
  and stays resident afterward; essentially no gaming desktop or laptop has a WWAN
  modem. Re-enable with `sudo systemctl unmask ModemManager.service` if needed

- **`kactivitymanagerd` memory cap** — `MemoryHigh=48M` / `MemoryMax=96M`; was
  already in Cortex's gaming-mode suspend list but had no systemd memory cap like
  the other background services. Its activity-tracking database grows over time
  even for users who never touch KDE Activities

- **GitHub Actions workflow overhaul** — `build.yml` now only triggers on changes
  to `recipes/**` and `files/**` (README/changelog edits no longer trigger a
  10–15 minute image build), runs on a weekly schedule to pick up upstream Bazzite
  updates, and cancels in-progress runs when a new push arrives. ISO building moved
  to a separate, manually-triggered `build-iso.yml` with Internet Archive upload
  support — ISOs are now built on-demand for releases rather than on every commit

### Changed

- **Smaller fresh install** — moved nine apps out of the default RPM install into
  the firstboot optional picker: GIMP, Inkscape, Krita, Darktable, Kdenlive, OBS
  Studio, Audacity, LibreOffice, and VLC. These pull in substantial dependency
  trees (color management, spell-check dictionaries, codec packs, separate Qt/GTK
  creative-app stacks) that previously added significant size to every install
  regardless of use. `mpv` remains as the default lightweight media player.
  `kamoso` (webcam booth app) removed entirely — rarely used, and Vesktop/OBS/
  browser all cover the same need

- **Radar arc HUD widget no longer auto-added to the panel** — removed from the
  default layout for stability (see Fixed, above). The plasmoid is still installed
  at `/usr/share/plasma/plasmoids/org.raptoros.radararc/` and can be added manually
  via Plasma's "Add Widgets" panel

## [v2.6.1] - 2026-06-11 (Build Hotfixes)

### Fixed

- **Vesktop not installing** — Flatpak ID changed from `com.vesktop.Vesktop` to
  `dev.vencord.Vesktop` when the project moved under the Vencord organisation on
  Flathub; the old ID returns 404, causing the `default-flatpaks` module to abort
  the build; corrected in `recipe.yml`, `raptor-app-choice.sh` (config path +
  `flatpak info` check + user override call), and `raptor-gaming.sh` (system override)

- **Kernel boot arguments not applying** — BlueBuild module type was `kernel-args`
  which does not exist; the correct name is `kargs`; additionally the argument list
  property was `addArgs` instead of `kargs`; both errors caused the module to fail
  schema validation and the build to abort, meaning `split_lock_detect=off`,
  `transparent_hugepage=madvise`, and the watchdog disables were never set on any
  v2.6 install

- **Network gaming configs not deploying** — `91-raptor-network.conf`,
  `raptor-network-modules.conf`, and `raptor-dns.conf` were referenced as static
  files in the `files` module but were not consistently landing in the repo;
  moved inline to `raptor-gaming.sh` using heredocs (same approach as memory sysctl,
  MangoHud, and gamemode configs); BBR congestion control, CAKE qdisc, TCP buffer
  tuning, and Cloudflare DoT DNS now reliably deploy with every build

## [v2.6] - 2026-06-11 (Full System Overhaul — Gaming, Audio, Network & Bug Sweep)

### Fixed

#### Critical — Firstboot & Services (were silently broken on all Wayland installs)
- **`raptor-firstboot.service` never ran on Wayland** — `ConditionEnvironment=DISPLAY`
  evaluates false on every Bazzite Wayland boot since `DISPLAY` is never set; replaced
  with `ConditionEnvironment=XDG_RUNTIME_DIR` which is present in both Wayland and X11
  sessions
- **`raptor-firstboot.service` was a system service trying to show a GUI** — installed
  to `/usr/lib/systemd/system/` and enabled as a system unit; system services have no
  display session, no D-Bus session bus, and no Plasma shell — dialogs cannot appear;
  converted to a user service at `/usr/lib/systemd/user/` and moved to `user.enabled`
  in recipe.yml
- **`raptor-app-choice.sh` installed nothing** — `FLATPAK_INSTALLS` array declared without
  `declare -A`; bash silently treated it as an indexed array, so every associative key
  lookup returned empty and no Flatpak was ever installed regardless of what the user selected
- **`raptor-app-choice.sh` dialog looped every boot** — Skip path exited without writing
  the stamp file; app selection dialog re-appeared on every login until an app was installed
- **Stamp files required root** — both firstboot scripts wrote stamps to `/var/lib/raptor/`
  which is not writable from a user service; moved to `~/.local/share/raptor/`

#### Critical — Cortex Profile Switching (buttons appeared broken)
- **Profile mode always showed "Balanced" active on launch** — `_current_mode` was
  hardcoded to `"balanced"` at startup with no system detection; if the actual mode
  differed, the wrong button was disabled and clicking the correct mode appeared to
  do nothing; mode is now read from `~/.config/raptor-cortex-mode` on launch
- **Mode selection did not persist** — switching to Performance and reopening Cortex
  reverted to Balanced every time; selection now written to disk immediately on switch
- **`set_use_markup(True)` on `Adw.ActionRow`** — unreliable in libadwaita; removed
  in favour of sensitivity and opacity changes that are guaranteed to work

#### Critical — Taskbar / HUD theme never applied on Plasma 6
- **All `kwriteconfig5` calls in `apply-plasma-panel.sh` do nothing on Plasma 6** —
  KDE 6 ignores kwriteconfig5 writes entirely; replaced with a `kwc()` shim that
  calls `kwriteconfig6` first with `kwriteconfig5` as a fallback
- **`plasma-changeicons` does not exist in Plasma 6** — command was removed upstream;
  replaced with `plasma-apply-icon-theme`
- **`DISPLAY=:0 plasmashell --replace` crashes on Wayland** — explicitly forcing `:0`
  tells plasmashell to start in X11 mode, which fails on a live Wayland session;
  removed the `DISPLAY=:0` prefix so plasmashell inherits the correct session environment

#### Performance Regressions
- **`RADV_DEBUG=nocompute` was in the Extreme GPU profile** — this flag disables the ACE
  (Async Compute Engine) on AMD RDNA hardware, which DX12, Vulkan, and modern Proton titles
  depend on for async reprojection, shadow rendering, and post-processing; removing it
  recovers 10–25% performance in affected titles
- **`echo 1 > /proc/sys/vm/drop_caches`** — value `1` only evicts page caches; corrected
  to `3` to also drop dentries and inodes, maximising free RAM before gaming
- **`raptor-zram.service` raced against `zram-generator.conf`** — both tried to claim
  `/dev/zram0` at boot; removed the manual service and its setup script; ZRAM is now
  managed exclusively by `systemd-zram-generator` via `zram-generator.conf`
- **`brave-optimized` was written to `/usr/local/bin/`** — `/usr/local` is reset to
  empty on every OSTree layer deployment; launcher disappeared after every system update;
  moved to `/usr/bin/` alongside all other Raptor scripts
- **`--use-gl=desktop` in Brave flags conflicts with Wayland** — this flag forces the
  GLX/EGL desktop backend which is incompatible with `UseOzonePlatform`; on Wayland
  sessions Brave either silently fell back to XWayland or failed to start the GPU
  process; removed with an explanatory comment

#### Update Manager
- **`check_for_updates()` treated exit code 77 as "no updates"** — `77` is not a
  documented rpm-ostree exit code; the check was misclassifying genuine errors as
  "system is up to date"
- **`fetch_changelog()` silently disabled TLS verification on first failure** — the
  `ssl.CERT_NONE` fallback loop sent requests over an unverified connection without
  any indication to the user
- **ANSI escape regex was incomplete** — missed ESC+single-character sequences
  (`ESC M`, `ESC c`, etc.) and OSC sequences terminated by `\x1b\\` (string terminator)
  rather than `\x07`; raw escape characters leaked into the update log
- **`Adw.MessageDialog` deprecated in libadwaita 1.5+** — Bazzite ships 1.6; every
  dialog open flooded the journal with GObject deprecation warnings; replaced with
  `Adw.AlertDialog` with a fallback to `MessageDialog` for older versions
- **`_countdown` lambda recreated a closure every second** — `lambda: (self._countdown
  (secs-1), False)[1]` was opaque and allocated a new object each tick; replaced with
  a named `_tick_countdown` method that returns `False` directly
- **`_do_reboot` discarded the Popen object** — if `pkexec` was cancelled or the
  helper failed, the error was swallowed silently; now waits for the process and
  surfaces failures as a warning in the status row
- **`raptor-update-launcher` set `DBUS_SESSION_BUS_ADDRESS` explicitly** — overriding
  the session bus with a uid-formula string breaks portal D-Bus calls when the actual
  socket path doesn't match; removed the override, relying on the session manager's
  correct value
- **`raptor-cpugovernor.service` failed to load** — unit file had `[[Unit]` (double
  bracket) making it syntactically invalid; also called `/usr/bin/raptor-cpugovernor.sh`
  which does not exist in the repo; service failed silently at every boot
- **`raptor-powerprofile.service` did nothing** — `Type=oneshot` with no `ExecStart`
  was a placeholder that completed immediately; now sets `balanced` as the boot default
  power profile via `powerprofilesctl`
- **`raptor-ensure-services.service` called `systemctl enable` at runtime** — on an
  immutable OSTree image the symlink target is read-only; the call either silently
  no-ops or fails; replaced with a health-check using `systemctl is-active` that
  attempts `systemctl start --no-block` for any failed services
- **`systemctl --user import-environment KEY=VALUE` was wrong** — `import-environment`
  accepts variable names already in the calling process's environment, not `KEY=VALUE`
  strings; GPU environment variables were silently never propagated to user sessions;
  switched to `set-environment` which accepts `KEY=VALUE` pairs directly
- **`raptor-powerprofile.service` not enabled** — was installed but never listed in
  recipe.yml `system.enabled`; now enabled after getting a real `ExecStart`
- **ZRAM swap-priority not set** — without an explicit priority ZRAM was ranked at
  the kernel default of `-2`, below any disk-based swap partition; set to `100`

---

### Added

#### Raptor Update Manager — Flatpak Support
- Flatpak apps now checked and updated alongside the system image — previously only
  `rpm-ostree` was handled; apps installed via the firstboot picker (Spotify, Godot, etc.)
  were never updated through the GUI
- Second status row in the UI shows Flatpak update state independently of the system row
- Update button adapts its label: "Update & Reboot" when an OSTree update is pending,
  "Update Flatpaks" when only Flatpak updates exist (no reboot triggered for apps-only updates)
- New `flatpak-update-helper` script with polkit policy and sudoers entry

#### Firstboot App Picker (Complete Rewrite)
- **20 optional Flatpak apps** across five categories: Communication (Telegram, Signal,
  Slack, Zoom), Productivity (VSCodium, ONLYOFFICE, Bitwarden, Joplin, MarkText, Calibre),
  Creative (Blender, Shotcut, Boatswain), Development (Godot Engine, GitHub Desktop, Pods),
  Gaming & Media (Lutris, Protontricks, Spotify, Plex)
- **Per-user app configuration runs before the dialog** — Vesktop memory flags, Firefox
  profile sync, and Flatpak user remote setup now apply unconditionally even when the
  user clicks Skip; previously these were in a separate `raptor-appconfig.sh` that
  required its own service and stamp file; merged and eliminated the extra files

#### Vesktop Memory & Wayland Optimisation
- System-level Flatpak override sets `OZONE_PLATFORM=wayland` — Vesktop previously
  ran through XWayland on Wayland sessions, consuming ~30 MB of extra address space
  per launch
- Per-user `flags.txt` caps V8 old-generation heap at 256 MB (Chromium default is ~1.4 GB
  on systems with free RAM and it never shrinks), limits renderer processes to 2
  (~80–120 MB each), enables VA-API hardware video decode for video calls and streams

#### Firefox Memory Overhaul
- New `/etc/firefox/policies/policies.json` system-wide defaults: memory cache capped
  at 64 MB (was 256 MB in user.js — 4× too large), content process count reduced from
  8 to 4, `browser.tabs.unloadOnLowMemory` enabled, media cache capped at 32 MB,
  session save interval raised from 15 s to 45 s
- `user.js` cleaned up: dead HTTP pipelining prefs removed (pipelining was removed from
  Firefox in version 83), GPU compositing and WebRender prefs retained and expanded
  with `media.ffmpeg.vaapi.enabled` and `gfx.webrender.program-binary-disk`

#### PipeWire Low-Latency Gaming Audio
- Default quantum lowered from 1024 to 256 samples — reduces round-trip audio latency
  from ~21 ms to ~5 ms at 48 kHz; stable on all modern hardware
- ALSA device auto-suspend disabled — prevents the ~120–300 ms audio glitch/pop that
  occurs when a game plays the first sound after a 5-second idle (device wake latency)
- PipeWire graph thread set to RT priority 88 via `libpipewire-module-rt`
- PipeWire and WirePlumber configured to auto-restart on failure (common after
  suspend/resume on AMD hardware); previously a crash left audio dead until logout

#### Network Gaming Optimisations
- **BBR congestion control + CAKE qdisc** — replaces CUBIC; BBR models bandwidth
  directly and maintains much lower queue depth, preventing ping spikes when a background
  download is running during a game session
- **128 MB TCP socket buffers** — the previous 256 KB default (a 1990s value) caused
  packet drops on high-bandwidth game server connections
- **TCP fast-open** — saves one RTT on reconnects to known game servers by sending
  data in the SYN packet; noticeable on game server rejoin after disconnect
- **No slow-start after idle** — prevents TCP from reverting to a tiny initial window
  after a brief pause; games have bursty traffic patterns
- **Cloudflare DoT as system resolver** — Cloudflare averages ~10 ms global DNS lookup
  vs ~40–80 ms for ISP resolvers; affects every new game server connection and
  matchmaking endpoint; systemd-resolved configured with Quad9 fallback and
  DNSSEC allow-downgrade

#### Kernel Boot Arguments
- `split_lock_detect=off` — disables kernel serialisation of split-lock memory accesses;
  some older Windows game ports under Proton trigger this frequently, causing measurable
  frametime spikes
- `transparent_hugepage=madvise` — lets games request 2 MB hugepages without forcing
  them globally (avoiding fragmentation on mixed workloads)
- `nowatchdog` + `nmi_watchdog=0` — removes periodic NMI watchdog timer interrupts
  from the CPU; these fire even mid-frame and show up as latency outliers in frametime
  graphs

#### MangoHud Default Theme
- Ships a default `/etc/mangohud/MangoHud.conf` matching the Raptor OS F-22 palette:
  `#020F12` dark background, `#33FF33` CPU, `#00D4FF` GPU, `#F5A623` engine, JetBrains
  Mono font; shows FPS, frametime graph, GPU/CPU stats + temps + clocks, VRAM, and
  Proton/Wine version; FPS colour thresholds at 45 and 60 fps; toggle with Shift+F12

#### Gamemode Full Configuration
- New `/etc/gamemode.ini`: AMD GPU power level raised to `high` while gaming (unlocks
  boost clocks and higher TDP budget); game processes reniced to -10; screensaver/DPMS
  inhibited during gaming; Steam, Heroic, Lutris, and Bottles registered as valid
  supervisors; previously gamemode was installed but ran with defaults, providing only
  a CPU governor switch
- `gamemoded.service` added to `user.enabled` — without this the daemon never started
  at login and `ENABLE_GAMEMODE=1` launch options silently did nothing

#### Input Device Improvements
- New udev rules disable USB autosuspend for all HID input devices — autosuspend saves
  ~0.5 W but causes 16–500 ms input latency spikes when the device wakes; unacceptable
  during gaming
- Proper `uaccess` permissions for DualSense (054c), Steam Controller/Valve Index (28de),
  and Xbox controllers via hidraw so tools like Chiaki and DS4Windows work without root
- `uinput` device set to `group=input mode=0660` for user-space virtual device creation
  (antimicro, xpadneo, sc-controller)

#### Baseline Memory Configuration
- New `/etc/sysctl.d/90-raptor-memory.conf`: `vm.swappiness=10`, `vm.vfs_cache_pressure=50`
  (holds VFS caches 2× longer — benefits games reloading assets from the same directories),
  proper dirty ratios, `vm.max_map_count=2147483642` — some 64-bit games (Elden Ring,
  Star Citizen via Proton) exhaust the default 65530 memory map limit and crash silently

#### Background Service Memory Caps
- systemd user drop-ins cap RAM on the five heaviest background services: Baloo file
  indexer (128 MB max — can exceed 400 MB during initial index), Akonadi PIM server
  (256 MB), KDE Connect (96 MB), Evolution Data Server (128 MB), GNOME file tracker
  (96 MB); users can raise individual limits in `~/.config/systemd/user/`

#### Fastfetch Themed Config
- Ships a default `/etc/xdg/fastfetch/config.jsonc` with Raptor OS colouring (green keys,
  cyan title, white values); shows OS, kernel, DE/WM/theme, CPU, GPU (via PCI), RAM,
  disk, and local IP

#### New Packages
- `mangohud` — explicit RPM (was implicitly provided by Bazzite base; now declared)
- `protontricks` — RPM for non-Flatpak use; complements Protontricks Flatpak in the
  optional app picker
- `partitionmanager` — KDE Partition Manager; previously absent from the install list

#### New Optional Apps in Firstboot Picker
- **Protontricks** — configure Steam/Proton game prefixes; install DirectX, Visual C++
  runtimes, .NET, and other Windows components for games that require them
- **EasyEffects** — PipeWire-native audio processing: EQ, bass boost, noise suppression
  for headset microphones
- **Warehouse** — browse, manage, and clean up installed Flatpak apps and accumulated
  runtimes (GNOME and KDE runtimes can accumulate 10+ GB over time)
- **Impression** — USB image flasher
- **CoreCtrl** — AMD GPU and CPU control: overclocking, undervolting, fan curves,
  and power limits without manual sysfs writes

---

### Changed
- Default Flatpak install list trimmed to core-only (Vesktop, Heroic, ProtonUp-Qt,
  Bottles, Flatseal, MissionCenter) — all optional apps moved to the firstboot picker
  so users choose what they actually want instead of getting everything pre-installed
- `raptor-app-choice.sh` now also handles all per-user app configuration inline before
  the dialog; the separate `raptor-appconfig.sh` script and `raptor-appconfig.service`
  unit have been eliminated
- Audio and network optimisations converted from build scripts (`raptor-audio.sh`,
  `raptor-network.sh`) to individual static config files with explicit
  `source → destination` mappings in recipe.yml — each file is now readable directly
  in the repo without running anything
- `raptor-cpugovernor.service` removed from `system.enabled` — CPU governor is handled
  by `raptor-gpu-profile.service` → `gpu-detect.sh`; the service file is retained on
  disk for compatibility but no longer starts at boot

## [v2.5] - 2026-05-21 (Script Consolidation, Build Fix & Radar HUD)

### Fixed
- **KDE Theme FINALLY fixed!**

### Added
- **Custom Radar HUD taskbar** — fully custom KDE Plasma panel replacing the default taskbar
  with an F-22 cockpit-inspired radar theme; features phosphor-green sweep line with
  persistence trail, randomised contact blips that light up as the sweep passes and decay
  between rotations, 8-point crosshair grid with diagonal lines, bearing tick marks around
  the rim, and a HUD status readout (clock, range label, IFF/MODE-S status); configurable
  arc colour, sweep colour, speed, opacity, and grid ring count via widget settings;
  panel corner radar arc decorations (`org.raptoros.radararc`) on both ends of the taskbar
  with live sweep, blip persistence, and HDG/ALT readouts

### Changed
- `raptor-performance.sh` and `raptor-ram-optimizer.sh` consolidated into unified `raptor-cortex.sh`
  — single script now handles CPU throttling, thermal management, memory compression (zram),
  gaming mode service suspension, and RAM optimization GUI; eliminates script duplication and
  simplifies maintenance
- `recipe.yml` script module updated to reflect consolidation — now lists only the six active
  scripts: `raptor-hud.sh`, `raptor-cortex.sh`, `raptor-gpu-profile.sh`, `raptor-gaming.sh`,
  and `raptor-update.sh`
- Comments in `recipe.yml` updated to note that zram sizing is now handled by
  `zram-generator.conf` at runtime rather than `raptor-performance.sh` at build time

## [v2.4] - 2026-05-20 (Full Script Overhaul)

### Fixed
- **Critical:** `raptor-firstboot.service` targeted `graphical.target` (system-level) instead
  of `graphical-session.target` (per-user session) — GUI dialog would fail to display on
  desktops where the session bus isn't available at the system target
- **Critical:** `raptor-firstboot.service` `ExecStart` path pointed to `/usr/local/bin/` —
  corrected to `/usr/bin/` to match the path `recipe.yml` installs the script to
- **Critical:** `raptor-firstboot.service` had a redundant `ExecStartPost=touch` writing the
  stamp file independently of the script — caused a race where the stamp could be written
  even if the browser dialog was cancelled, permanently suppressing the dialog; stamp
  management is now owned exclusively by `raptor-browser-choice.sh`
- **Critical:** `raptor-ensure-services.service` only guarded `raptor-gpu-profile.service` —
  `raptor-powerprofile.service` and `raptor-cpugovernor.service` were silently never
  re-enabled if accidentally disabled
- **Critical:** `raptor-browser-choice.sh` had no prerequisite check for `zenity` — on
  minimal or headless boots the script would crash with an unhelpful "command not found"
  rather than logging and exiting cleanly
- **Critical:** `raptor-browser-choice.sh` "Decide Later" / dialog close wrote the stamp file,
  permanently suppressing the browser choice dialog even though the user never made a
  selection — cancellation now exits without writing the stamp so the dialog re-appears
  next session
- **Critical:** `raptor-update.sh` Python GUI — `_run_update` always called `_on_update_success`
  regardless of `rpm-ostree` exit code; a failed update would incorrectly trigger the
  reboot countdown — now checks `returncode` and routes to `_on_update_error` on non-zero
- `raptor-browser-choice.sh` stamp file location moved from `/var/lib/` root to
  `/var/lib/raptor/` — consolidates all Raptor OS runtime state under one directory
- `raptor-ensure-services.service` did not start newly-enabled units immediately — `--now`
  added so units come up in the current boot rather than waiting for the next reboot
- `raptor-update.sh` icon colour changed from `#33ff33` (harsh neon green) to `#4a9eff`
  (blue) to align with standard GNOME/KDE accent colour conventions and reduce visual clash

### Added
- `btop` added to RPM packages as a modern, full-featured alternative to `htop`
- `raptor-ensure-services.service` now included in the `files` module of `recipe.yml`
  and added to the `systemd` enabled list — it was referenced but never actually deployed
- `raptor-firstboot.service` now sets `SuccessExitStatus=0 1` so a headless boot or
  user cancellation does not mark the unit as failed in `journalctl`
- `raptor-browser-choice.sh` shows a user-facing error dialog if the Brave Flatpak
  installation fails, with Firefox kept as the fallback default
- `raptor-browser-choice.sh` dialog enriched with a Notes column describing each browser
  ("pre-installed" / "will be downloaded from Flathub") to inform the user before choosing
- Per-unit `logger` calls in `raptor-ensure-services.service` — each service enable/fail
  is individually reported to the journal under the `raptor-ensure-services` identifier
- `build.yml` now triggers on pull requests to `main` so CI validates changes before merge
- `build.yml` weekly scheduled rebuild (Sundays 04:00 UTC) to automatically pick up
  upstream Bazzite base image updates
- `build.yml` `concurrency` block cancels stale in-progress runs on new pushes
- `build.yml` ISO artifact upload now includes the `.sha256` checksum file alongside
  the ISO for integrity verification
- `Containerfile` now includes full OCI standard `LABEL` block (title, description,
  URL, source, vendor, license)
- `raptor-update.sh` icon symlinks now include `128x128` in addition to `48x48` and
  `256x256` for better icon theme coverage
- `raptor-update.sh` `.desktop` entry `Categories` field expanded with `System;Settings;`
  for correct placement in KDE and GNOME app menus

### Changed
- All scripts overhauled with `set -euo pipefail` and structured `logger` logging —
  errors now surface in `journalctl` with identifiable tags rather than silently swallowing failures
- `recipe.yml` `image-version` changed from `latest` to `stable` for safer, reproducible builds
- `recipe.yml` RPM package list reorganised into labelled sections (Browser, System Utilities,
  KDE Extras, Power Management, Multimedia, Creative, Gaming, Development, etc.) for readability
- `raptor-ensure-services.service` `ExecStart` rewritten from a single hardcoded `systemctl`
  call to a loop over all three Raptor services with existence checks before enabling
- `raptor-update.sh` Python GUI refactored — all methods renamed to `_private` convention,
  `_strip_ansi()` extracted as a named top-level function, `check_for_updates()` and
  `fetch_changelog()` separated as standalone testable functions
- `build.yml` `registry_token` corrected from deprecated `${{ github.token }}` shorthand
  to `${{ secrets.GITHUB_TOKEN }}`
- `build.yml` ISO job now skips on pull request events — ISOs are only built on merges to main
- `build.yml` artifact `retention-days` extended from 5 to 14 days
- `build.yml` disk cleanup step added to the ISO job (was previously only in the build job)

## [v2.3] - 2026-05-08 (Build System & App Fixes)

### Fixed
- **Critical:** `recipe.yml` YAML parse failure — `- type: rpm-ostree` module entry was
  at column 1 instead of indented under `modules:`, causing the entire build to fail
  validation before any package installation
- **Critical:** `raptor-performance.sh` line 153 crash — `cat` attempted to write
  `/etc/raptor/thermal-idle.conf` before `mkdir -p /etc/raptor` was called; directory
  creation moved above the write
- **Critical:** `raptor-cpugovernor.service` systemd unit parse failure — multiline
  bash inside `ExecStart=` was being interpreted as invalid section headers; collapsed
  to a single-line command
- **Critical:** Heredoc EOF error in `raptor-performance.sh` — `cat << 'CONF'` block
  containing single quotes in `ExecStart=` caused the shell to never find the closing
  delimiter; fixed by switching to unquoted `<< CONF` with `\$` escaping for the
  affected block
- **Critical:** `raptor-performance.sh` file truncation during copy — script was being
  cut off mid-line at the Firefox prefs block, causing `unexpected EOF` errors at
  build time
- **Critical:** `raptor-ram-optimizer.sh` build failure — `chmod 440` on sudoers file
  and missing `mkdir -p /etc/sudoers.d` caused silent non-zero exit under `set -e`;
  fixed with `|| true` guards and `visudo -cf` validation
- **Critical:** Steam (Flatpak) silently failing to launch — `memlock unlimited` in
  `/etc/security/limits.d/raptor-gaming.conf` conflicted with Flatpak sandbox fd
  limits; replaced with a bounded value of 8 GB (8388608 KB)
- **zram Compression** status in Raptor RAM Optimizer incorrectly reported "zram not
  active" despite zram being correctly configured and mounted — fixed detection to
  read `/sys/block/zram0/disksize` for existence check and distinguish between idle
  (nothing swapped yet) and truly inactive
- **zram sizing** evaluated at image build time using the build container's RAM rather
  than the end user's hardware — noted as a known limitation pending a runtime
  firstboot service fix
- **Update Manager** output was severely buffered — rewritten to use `script -q -c`
  to force a PTY, giving real-time line-by-line output matching terminal speed
- **Update Manager** reboot countdown did not trigger `systemctl reboot` after update
  completed — fixed with dedicated `_reboot_cancelled` flag initialized in `__init__`
  and `getattr` guard in countdown to prevent silent `AttributeError` deaths
- **Update Manager** ANSI escape codes were printed raw into the log view — now
  stripped before display for clean readable output
- **Update Manager** switched from `ujust update` to `rpm-ostree update` — `ujust`
  is not available in all environments and would silently fail with "not found"

### Added
- mpv media player
- qBittorrent torrent client
- Bitwarden password manager (Flatpak)
- Thunderbird email client (re-added)
- Raptor Cortex game mode — per-service toggle in RAM Optimizer GUI; selected services
  auto-suspend on game launch via gamemode hooks and resume on game exit
- No-auth RAM optimization — all privileged actions consolidated into a single
  `NOPASSWD` sudoers helper, eliminating repeated password prompts
- Raptor RAM Optimizer now writes `/etc/raptor/cortex-suspend.conf` to persist
  per-user service suspension preferences across reboots
- Update Manager now shows a Cancel Reboot button during the post-update countdown
  so users can defer the reboot if needed
- Update Manager log view now auto-scrolls to the latest output line

### Changed
- Raptor Update Manager fully rewritten — previous version silently crashed on launch
  due to missing `DBUS_SESSION_BUS_ADDRESS` in the wrapper launcher; new version adds
  automatic update check on launch, live changelog loaded from GitHub, live log output
  during update, and automatic 15-second countdown reboot on success
- Update Manager flow now mirrors Windows Update: check → confirm → update → reboot
  with cancellable countdown
- Raptor RAM Optimizer rewritten — all privileged operations consolidated into a single
  sudo call, Razer Cortex-style per-service game mode toggles added, gamemode hooks
  integrated for automatic suspend/resume on game launch and exit

## [v2.2] - 2026-05-07 (Major Fix)

### Fixed
- **Critical:** `vm.overcommit_memory` corrected from mode 1 (always overcommit) to mode 0
  (heuristic) — mode 1 allowed Unity/Unturned to silently allocate past physical RAM,
  causing hard crashes at the RAM ceiling
- **Critical:** Conflicting `vm.swappiness` values between `raptor-memory.conf` and
  `raptor-gaming.conf` resolved — duplicate entries caused unpredictable boot-order
  races; swappiness is now owned exclusively by `raptor-memory.conf`
- `vm.swappiness` raised from 60 to 80 — zram is in-RAM compressed swap (~10× faster
  than disk), so a higher swappiness aggressively compresses cold pages instead of
  triggering the OOM killer on spikes
- `vm.page-cluster` set to 0 — default value of 3 caused 8-page read-ahead on every
  zram fault, wasting memory and adding latency on compressed swap
- `vm.min_free_kbytes` raised from 64 MB to 128 MB to prevent page allocator stalls
  under heavy RAM pressure
- `vm.watermark_scale_factor` raised from 125 to 200 so the kernel begins reclaiming
  pages earlier, before hitting the RAM ceiling
- `vm.compaction_proactiveness` re-enabled (set to 20) — was incorrectly set to 0,
  which disabled proactive memory compaction
- `vm.oom_kill_allocating_task` enabled — kernel now kills the process that triggered
  the OOM event (e.g. Unturned leaking memory) instead of hunting an unrelated victim
- `raptor-browser-choice.sh` shebang corrected from `#!/usr/bin/bash` to `#!/bin/bash`
  — would silently fail on systems without the symlink
- `raptor-browser-choice.sh` cancel/close now exits with code 0 instead of 1 — closing
  the dialog was incorrectly treated as an error
- `raptor-gpu-profile.sh` performance override profile was missing `RADV_PERFTEST=gpl`
- Dangerous PID loop removed from `raptor-ram-optimizer.sh` — it attempted to set
  `oom_score_adj` on every running process, which had no practical effect (value of 4
  is near-zero in the -1000 to 1000 range) and risked interfering with system processes;
  kernel-level OOM behaviour is already handled by `vm.oom_kill_allocating_task=1`

### Added
- `WINE_LARGE_ADDRESS_AWARE=1` and `PROTON_FORCE_LARGE_ADDRESS_AWARE=1` added to all
  GPU profiles — allows 32-bit Unity builds (including Unturned) to address more than
  2 GB of RAM under Proton/Wine
- `STAGING_SHARED_MEMORY=1` added to all GPU profiles for more efficient cross-process
  memory sharing under Wine/Proton
- System-wide `ulimits` raised for all users: `nofile` to 1,048,576 and `memlock` to
  unlimited — Unity asset streaming silently fails at the default 1024 file descriptor
  limit on large maps
- Hint file written to `/etc/raptor/unturned-launch-options.txt` with recommended Steam
  launch options including `-gc.maxreserved 128` to cap the mono GC heap reservation,
  the single largest source of Unturned RAM bloat
- Added custom app for updating instead of using cmds

## [v2.1] - 2026-05-04 (Mini Hotfix)

### Fixed
- GPU detection now correctly identifies AMD/ATI cards including iGPUs like Cezanne
- Firefox RAM usage significantly reduced via aggressive memory limits in defaults/pref
- Firefox telemetry and background tasks disabled to reduce memory overhead
- Hardware video decoding enabled in Firefox for lower CPU usage

## [v2.0] - 2026-05-04 (Major Update)

### Added
- (Skipped to v2.0 as this was a major update mainly focusing on performance)
- Automatic GPU vendor detection (AMD/NVIDIA/Intel/iGPU)
- Per-vendor GPU optimization profiles
- Performance Mode toggle with GUI — choose Auto or Max Performance
- RAM spike protection for large game maps and memory intensive apps
- WiFi stability fix — disables power saving to prevent random disconnections
- Split build scripts into raptor-hud, raptor-performance, raptor-gaming and raptor-gpu-profile
- Raptor Profile Switcher app — switch between Auto and Max Performance GPU profiles from the app menu
- Shotcut video editor
- Made ZRAM dynamic based on available RAM for better performance

### Fixed
- WiFi randomly disconnecting and not reconnecting
- RAM ceiling hits during large map loading in games like Unturned
- GPU settings now correctly differentiate between iGPU and dGPU

## [v1.2] - 2026-05-04

### Added
- Calibre ebook manager
- Joplin note taking app
- Pods GUI for Podman containers
- MarkText Markdown editor
- Mission Center task manager
- ProtonUp-Qt for managing Proton versions
- Blender 3D modeling
- Flatseal Flatpak permission manager
- Bottles Windows app compatibility layer (returned by popular demand)
- KCalc calculator
- Kamoso webcam app
- BleachBit system cleaner
- Darktable photo editor
- Audacity audio editor
- Boatswain stream deck controller

### Fixed
- KDE theme accent color now uses kwriteconfig6 for Plasma 6 compatibility
- App menu refresh via kbuildsycoca6
- Steam dev config path not existing during build
- raptor-theme.sh not being created during build

## [v1.1] - 2026-05-02

### Added
- Inkscape and Krita for graphics work
- VLC media player
- OBS Studio for streaming and recording
- Variety wallpaper changer
- Wine and Winetricks for Windows app compatibility
- Development tools: Git, GitHub CLI, Node.js, Python 3, GCC, Make
- Additional dev tools: CMake, Ninja, Meson, Neovim, htop, Podman, jq, ripgrep, fzf, tmux
- Podman and Podman Compose for containerization
- Gamemode and GOverlay for gaming performance
- Filelight disk usage analyzer
- Gwenview image viewer
- Automatic Cloudflare DNS (1.1.1.1) for better internet performance
- First boot browser choice dialog (Firefox or Brave)
- Neon green KDE theme now applies system-wide
- Steam and Lutris gaming optimizations (async shaders, shader caching, DXVK)
- zram enabled by default for better memory management
- KDE theme now force reloads on boot

### Fixed
- DNS sluggishness via systemd-resolved configuration
- Firefox RAM usage via performance tweaks and memory hard limits
- KDE theme not applying to existing users
- Steam and Firefox high idle memory usage via zram and config tweaks

## [v1.0] - 2026-05-01

### Added
- Initial release based on Bazzite
- Neon green KDE theme (Breeze Dark with green accents)
- Firefox with performance tweaks
- Fastfetch system info display
- Brave Browser option via first boot browser choice dialog
- Discord, VSCodium, Heroic Games Launcher as Flatpaks
- LibreOffice, Thunderbird, Kdenlive, GIMP
- First boot service that automatically rebases to Raptor OS from stock Bazzite
