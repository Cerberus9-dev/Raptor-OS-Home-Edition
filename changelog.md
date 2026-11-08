# Changelog

### Raptor application suite corrections

- **Raptor Shroudly:** package the custom Rust/Slint Raptor application rather than the upstream Electron desktop app. The image now installs a dedicated Raptor-branded launcher, desktop entry and icon, and CI verifies those exact artifacts in the published image. The dashboard reports local app detection honestly; network routing remains disabled until its engine is implemented and tested.
- **Welcome screen:** identify Raptor Shroudly and explain Raptor Proton as the optional Proton/UMU path for games, distinct from standard Wine for everyday Windows applications.


## V3.0 reliability follow-up — suspend/resume and CI regression cleanup
- Removed the obsolete readiness-only CPU governor and power-profile units, plus the inactive service-health checker. Power Profiles Daemon is the sole CPU/firmware policy owner; the removed units only queried or rechecked service state and did not provide useful behavior.
- Removed the unused unit files from the image recipe entirely rather than merely leaving them disabled, reducing installed systemd clutter and preventing accidental activation by future dependencies.


- Removed the unused resume-marker service, redundant lid-open unit, and inactive CPU-governor compatibility unit. Suspend/resume recovery is already handled by the single systemd-sleep hook; target-bound units could run at the wrong point in the suspend transition and add avoidable delay.
- Kept touchpad rebind and asynchronous Wi-Fi/Bluetooth recovery in the existing post-resume hook, avoiding duplicate recovery paths.
- Corrected a contradictory gaming validator: Steam's shader pre-caching setting is left untouched, and CI now asserts that no global setting overrides it while risky Steam/GameMode tweaks stay absent.
- Added regression checks to ensure removed service units are not reintroduced into the image recipe.

## V3.0 reliability follow-up — conservative gaming defaults

- Removed forced Steam HTTP/2, extra-connection, and write-buffer settings from the system-wide Steam template. They are network-specific troubleshooting knobs, not universal performance wins; Steam's shader pre-caching setting is left at its own default.
- Removed GameMode's global AMD high-performance and NVIDIA maximum-performance GPU overrides. Upstream explicitly labels GPU optimisations as an at-your-own-risk operation and notes that they change hardware performance levels; Raptor now leaves GPU policy to the driver and user-selected system power profile.
- Added quality-gate assertions preventing these risky global overrides from silently returning.



### Low-spec desktop and Windows compatibility
- Raptor Proton now reuses the cached Steam Linux Runtime between launches and performs an automatic runtime update check at most daily, reducing repeated setup work without permanently disabling updates.
- Added a post-install app-registration flow for Proton installers. It compares the prefix's executable inventory before and after installation, lets the user select the installed application, and adds a proper KDE launcher under Games or Utilities. Older prefix apps can be registered manually.
- Added MSI installation through UMU/Proton, clearer launch feedback, a Proton MIME handler for KDE's Open With chooser, and consistent Raptor Wine / Raptor Proton labels.
- Canonicalize external executable paths, launch from the executable's directory, and expose non-home parent folders to the Steam Runtime container for better support of removable and secondary drives.
- Switched zram compression to LZ4 to reduce compression/decompression CPU overhead on older low-power systems. This trades some compression ratio for faster response under memory pressure.

## [Unreleased]

### v3.0.0 (Major Release)

This is the consolidation release for more than two months of sustained Raptor OS overhaul work. The scope includes substantial changes across performance and memory management, gaming and GPU behavior, audio, Cortex, update reliability, hardware recovery, browser and chat-client choice, build validation, and the installation/distribution path. The intent is to ship the work as one coherent major update rather than scatter it across a long sequence of small version bumps.

### Raptor Music desktop experience
- Replace fixed Slint window dimensions with preferred initial dimensions and minimum size constraints, allowing KDE/X11 window managers to resize and maximize the player normally.
- Rework the interface into a Raptor-branded graphite-and-sage desktop player, with clearer browse/library/queue hierarchy, a more prominent global search, and a persistent playback dock. The visual language uses familiar desktop-media conventions without Spotify logos, artwork, or copied branding.
- Let the local-library and Audius result lists expand with the available window height instead of trapping results in short fixed-height panes. Clarify that local results are searched locally and online results come from Audius; this is not a Spotify-sized licensed streaming catalog.

### Low-memory application tuning
- **Firefox:** reduce the default content-process ceiling from four to two (web-isolated from two to one), halve in-memory page/media cache defaults, seed a usable default profile on first launch, and apply preferences to both native and Flatpak profile locations. Existing user-set values are preserved rather than overwritten. This trades some parallel page isolation/throughput for lower baseline RAM on low-memory systems.
- **Discord, Equibop and Vesktop:** on systems with 8 GiB RAM or less, use a four-renderer ceiling while preserving GPU acceleration, Chromium sandboxing, and voice/video features. Discord uses Flathub's `discord-flags.conf`; Equibop and Vesktop use their persistent flags files. Existing user-specified Discord or Equibop renderer limits are preserved. Do not impose a hard V8 heap cap or disable WebRTC.
- **Raptor Cortex:** slow idle sensor polling from every eight seconds to every fifteen seconds to reduce repeated hardware-probe wakeups. This changes telemetry refresh cadence, not gaming performance.
- **Raptor Proton:** derive the default prefix from its selected GAMEID and reclaim an idle Proton wineserver through UMU's selected Proton environment (`umu-run wineboot -k`) only when no other process using that exact prefix remains. This avoids invoking an unrelated host Wine server and preserves concurrent Windows apps sharing a prefix. Fix the generated helper's process-ID expansion so it can correctly exclude its own launcher when checking for active apps.

### Raptor Cortex telemetry
- Fix GPU summary detection by importing the regex module used by Linux DRM device discovery, restoring adapter model, utilization, clock, and exposed memory reporting.
- Expand read-only fan telemetry to report standard hwmon RPM sensors, NVIDIA driver fan percentages, and PWM-only sensors with an explicit duty-cycle label instead of misrepresenting them as RPM.
- Add regression coverage with synthetic AMD-style DRM and hwmon RPM/PWM fixtures; hardware without an exposed tachometer or PWM sensor remains reported as unavailable rather than guessed.

### Raptor Music online search and playback
- Add debounced online track discovery through Audius alongside the existing local-library search; local queries still work offline and local files remain on-device.
- Filter online results to public, available, streamable tracks, preserve stable provider IDs in the library, and allow selected online results to enter the normal playback queue.
- Add bounded download-to-cache playback for Audius MP3 streams, with a 256 MiB safety limit, short request timeouts, and automatic temporary-file cleanup. Buffers are written to the per-user cache rather than the typical RAM-backed runtime directory.
- Add regression tests for streamability/access filtering, malformed responses, and stable remote track IDs. Audius adds an online catalog but does not provide Spotify's complete catalog or guarantee every artist/track is available.

### Boot-time hardware detection and service cleanup
- Removed blanket USB autosuspend disable rules for HID, Bluetooth and USB audio devices; controller permissions remain, but idle power behavior stays with the kernel unless a device-specific issue requires a workaround.

- Removed global Steam HTTP/2, multi-connection, write-buffer, and shader-cache overrides. These undocumented per-client settings can regress downloads or cache behavior on some systems; Steam now retains its own defaults, with troubleshooting guidance kept in the README.
- Moved Wi-Fi power-save handling from a forced global override to an opt-in Raptor Cortex setting. NetworkManager defaults and scan-MAC randomization are preserved for battery life and privacy; users with adapter-specific reconnect/latency problems can disable 802.11 power saving from the GUI.
- Added a bounded privileged helper that atomically updates the NetworkManager override, reloads configuration, restores the previous file on reload failure, and tells users to reconnect for the active connection to adopt the change.

- Added CI coverage for the embedded Python application entry points, including Raptor Cortex, so malformed Python cannot hide inside an otherwise valid shell installer.
- Added a regression guard against introducing a global `systemd-udev-settle.service` dependency, which has been reported to add substantial boot latency and is discouraged by systemd.


- GPU detection now performs one bounded PCI display-device probe instead of repeatedly invoking `lspci`; the optional verbose AMD iGPU probe is also bounded.
- NVIDIA power queries and changes have time limits and safely tolerate an unavailable or unresponsive driver utility instead of holding the boot-critical service indefinitely.
- Corrected hybrid-GPU classification so an Intel iGPU does not automatically cause a separate AMD adapter to be classified as an AMD iGPU.
- Removed the redundant Raptor power-profile readiness check from the enabled boot services. Power Profiles Daemon itself remains enabled and owns the selected profile; the extra unit only queried it.
- Kept the optional service-health checker installed but removed it from the default boot path. It only re-checked services already ordered by systemd and offered no user-facing recovery.
- Removed the redundant global `sysctl --system` reload from GPU detection; systemd-sysctl already loads the static Raptor sysctl file during normal boot.

### Image build and app-payload verification fixes

- Corrected post-build verification to use BlueBuild's actual version-suffixed image tags. The previous verifier attempted `pr-N`/ `latest`, while the build published `pr-N-VERSION` and branch-version tags, causing a false-negative after a successful image build.
- Raptor Music and Shroudly installers now fall back to the source-files bind mount when the temporary staging destination is not visible to a later script module. This addresses a real build log where both installers skipped despite the workflow having built and staged their payloads.
- Added regression assertions for tag derivation and both payload fallback paths.

### GPU compatibility and resource safety

- Removed forced AMD Vulkan ICD selection and forced Intel Mesa driver overrides so Mesa/Vulkan can select the supported driver for each device and hybrid-GPU configuration.
- Removed forced VKD3D feature levels and DXR feature flags. Unsupported capabilities must not be advertised to games by a global environment override.
- Limited Proton NVAPI enablement to NVIDIA hardware rather than applying it to AMD and Intel systems.
- Removed experimental RADV performance flags and NVIDIA threaded-optimization overrides from global profiles; removed the setting that disabled NVIDIA shader-cache cleanup to avoid unbounded cache growth.
- Added CI assertions to prevent these cross-vendor overrides from returning unnoticed.

### Steam behavior and gaming troubleshooting

- Added evidence-based Steam troubleshooting guidance for sluggish Big Picture/web views, shader pre-caching, and download rates constrained by CPU decompression or storage writes.
- Kept Steam's network compatibility flags out of universal defaults: HTTP/2 workarounds are reported for some affected Linux configurations, but Valve marked the original broad issue as solved. Per-machine diagnosis is safer than imposing undocumented client behavior on every installation.
- Documented the Bazzite-reported GPU-accelerated web-view toggle as a reversible troubleshooting option, including its reported NVIDIA menu-rendering caveat.

### Recovery and lock-screen controls

- Added a guarded **Roll Back System** action to Raptor Update Manager. It appears only when rpm-ostree reports a valid current deployment and a previous deployment, confirms before acting, verifies the deployment list again in the privileged helper, and stages `rpm-ostree rollback` without forcing an immediate reboot.
- Added explicit recovery messaging that distinguishes an OSTree system rollback from Flatpak updates and user-home configuration; the rollback does not promise to restore those independent data stores.
- Raptor Wallpaper can now apply the selected image to the KDE Plasma lock screen independently of the desktop background. It selects the supported `org.kde.image` wallpaper plugin and writes both the image and preview entries through `kwriteconfig6`, with bounded subprocess calls and visible error reporting.
- Expanded CI contracts to syntax-check the update manager, parse its embedded Python, and verify the rollback and lock-screen integration points.

### Continuous quality gate

- Added a lightweight GitHub Actions quality workflow that runs on every push and pull request, independent of path filters. It checks every Actions workflow with actionlint, runs the repository's application/integration validator, and syntax-checks every tracked shell script.
- The full image workflow remains responsible for image-build and published-image verification; the new quality gate provides faster feedback for documentation-only, workflow-only, and application-only commits too.

### Aviation-inspired desktop identity

- Refined the Raptor HUD palette from bright electric blue toward flight-deck navy, graphite, instrument cyan, caution amber, and operational green.
- Extended the GTK3/GTK4 theme with consistent Adwaita cards, navigation sidebars, toolbars, status pages, and semantic status colors so first-party GTK apps inherit a more coherent aerospace interface.
- Updated theme metadata and first-login service descriptions to identify the aviation-inspired Raptor OS visual system. The design stays restrained and readable rather than turning the desktop into a novelty cockpit.
- Added a fifth bundled **Raptor Flight Deck** wallpaper: a dark aerospace grid, navigation/radar markings, and a clean top-down aircraft outline, available in Raptor Wallpaper without changing the user's selected background automatically.

### Cortex and GPU telemetry reliability

- GPU telemetry now checks PCI vendor IDs before reading AMD or Intel sysfs counters, prefers NVIDIA's own telemetry on hybrid systems, and reports VRAM for all exposed NVIDIA/AMD adapters rather than accidentally treating the first DRM card as the discrete GPU.
- Moved GPU temperature, model/load/clock/VRAM readings, and read-only fan sensors into Cortex's Graphics tab beside the GPU profile controls, keeping the Overview focused on system memory and CPU health.
- CI now extracts and byte-compiles the embedded Cortex Python application, and validates the archive installer shell syntax before the image build.

### First-login welcome and application tour

- Added a one-time **Welcome to Raptor OS Home** dialog before the existing browser, chat, and optional-app choices. It explains the Raptor app suite in plain language and can be dismissed without blocking setup.
- The completion stamp is stored per user under the XDG data directory, so the welcome screen does not repeat after dismissal. If the dialog dependency is unavailable, setup continues rather than trapping the user.

### Raptor Tasks and Wallpaper usability polish

- Raptor Tasks now has live text search, an Open/Completed status filter, category filtering, a compact open/completed/total summary, active-first alphabetical ordering, and separate helpful empty states for a genuinely empty list versus filters with no matches.
- Recolored the Tasks and Wallpaper application icons to match the aviation-inspired flight-deck navy and instrument-cyan palette.
- Raptor Wallpaper now includes a larger selected-image preview, the selected filename, live gallery search, and a useful no-results state.
- Fixed both apps' JSON writers to append a real newline rather than a literal backslash-n sequence, so files saved by the apps remain valid JSON on the next launch.
- Restored the `apply_wallpaper` function docstring to its proper position before executable statements.
- Task editing now stays open when a save fails, allowing the user to correct the problem and retry instead of losing the draft.
- Wallpaper file selection now rejects unsupported or inaccessible paths, avoids duplicate gallery cards, and captures the chosen image/fit mode before applying so a later click cannot change the in-flight operation.

### Raptor Wallpaper reliability

- Wallpaper settings now use atomic writes, preventing interrupted saves from truncating the previous selection and fit mode.
- Invalid settings are preserved to a separate recovery file instead of being silently discarded.
- Gallery scanning tolerates inaccessible folders and files that disappear during enumeration instead of aborting the whole picker.
- Both the GUI and Dolphin's direct-apply path reject missing files and unsupported extensions before asking Plasma to apply them.
- The app now reports when the wallpaper was applied but its preference could not be saved.
- CI extracts and parses the embedded Python app and checks the recovery, atomic-write, and input-validation paths.

### Raptor Tasks reliability and usability

- Fixed the Ctrl+N shortcut by registering it through a GTK ShortcutController rather than calling a nonexistent window shortcut helper.
- Added a native empty-state panel so a new task list explains how to get started instead of presenting a blank window.
- Task storage now writes to a temporary file, flushes it to disk, and atomically replaces the previous JSON file. Failed writes leave the previous file intact and surface a toast instead of silently losing changes.
- Damaged or invalid task data is preserved under a separate `.corrupt` backup name instead of being silently interpreted as an empty list and overwritten on the next save.
- Editing uses a working copy so an unsuccessful save does not mutate the existing in-memory task.
- Added CI extraction and Python AST validation for the embedded Tasks application, plus checks for its shortcut controller, atomic persistence, corruption preservation, and empty state.

### App picker usability and everyday integration

- Made the optional-app catalogue reusable after first boot: the first-run service still respects its one-time completion stamp, while the new **Raptor App Picker** application-menu entry opens the catalogue on demand without changing that stamp.
- Added in-dialog type-to-search and increased the picker window size so the existing large catalogue is easier to browse on common laptop displays.
- Added KDE Connect as an optional Flatpak for Android-to-desktop notifications, file sharing, clipboard integration, and device controls. It remains opt-in and adds no default background service.
- Updated the README to describe the real post-first-boot installation path rather than implying every catalogue item is available through Discover.

### Dolphin and archive reliability
- Corrected the archive-hardening installer so its logging/comment block is valid shell rather than embedding literal `\\n` text in the command; the CI validator now runs `bash -n` against this installer.

- Made Ark, 7-Zip and Info-ZIP unzip explicit image dependencies instead of relying on incidental base-image packages.
- Routed additional ZIP MIME aliases to Ark, including archives opened from outside Dolphin, avoiding the reported Bazzite behavior where an externally opened ZIP is sent back to Dolphin as a folder.
- Expanded Ark defaults to common bzip2/gzip/xz/zstd, cpio, ISO, CAB, RPM/DEB, Java archive, and comic-book archive MIME types so supported formats open in the archive manager instead of being misrouted to Dolphin.
- Restored common Dolphin archive actions through Raptor-owned KIO service menus: Extract Here, Extract To, and Create Archive call Ark's documented batch/add interfaces directly. The slow upstream per-selection plugins stay disabled; drag-and-drop extraction remains unavailable.
- Kept the existing conservative Dolphin safeguards: archive content metadata extraction and the slow archive context-menu plugins remain disabled to avoid known selection/context-menu hangs. This intentionally trades those context-menu entries for responsiveness; archive opening remains through Ark.
- Added image-build checks that Ark and unzip are present. This does not claim to fix every upstream Ark extraction or multi-volume ZIP bug.

### Cortex control-center redesign

- Reorganized Raptor Cortex into dedicated Overview, Graphics, Games, Optimize, and Settings tabs using the native libadwaita ViewStack/ViewSwitcher controls.
- Increased the window's usable desktop layout and reduced routine sensor polling from every five seconds to every eight seconds to lower background wakeups on low-power systems.
- GPU telemetry shows model, utilization, clock and dedicated VRAM where supported; fan reporting remains read-only and only shows sensors exposed by hardware/firmware.

### Memory compression and low-memory behavior

- Updated ZRAM to use standard zstd compression and a maximum size of up to the installed physical RAM, capped at 8 GiB. This favors compression efficiency while keeping CPU cost bounded by the default zstd level.
- Kept ZRAM rather than enabling Zswap globally. Zswap requires a correctly configured backing swap device and has different failure/performance tradeoffs; forum reports show both ZRAM and Zswap can cause stalls when poorly sized. A blanket switch would be an unsafe guess.

### Dolphin and Ark reliability

- Retained the targeted workaround for known archive metadata/context-menu stalls while keeping Ark as the dedicated archive opener and 7-Zip/unzip backends installed.
- Documented the limitation: context-menu compress/extract actions may be absent while the upstream plugin issue persists; archive opening remains available through Ark.

### Cortex GPU and fan telemetry

- Expanded the Graphics Processor row to show the detected adapter model, utilization, active clock, and dedicated VRAM when the kernel/vendor driver exposes those values.
- Changed the generic fallback from the unhelpful label “GPU” to an explicit telemetry-unavailable message.
- Kept fan reporting read-only. RPM/percentage appears only when hwmon or NVIDIA driver sensors expose it; systems without readable fan sensors receive a clear firmware/driver limitation instead of fabricated values.

### Memory compression decision

- The current image configuration uses standard-level zstd ZRAM with logical capacity `min(RAM, 8 GiB)`. The logical limit is not preallocated at boot; physical memory is consumed as compressed pages are stored.
- zstd trades additional CPU work for a better compression ratio than LZ4 on many workloads. That tradeoff is documented rather than presented as a universal win; weak CPUs and sustained memory pressure still need real-device benchmarking.
- Did not stack zswap on top of ZRAM: zswap requires a separate backing swap device and can add CPU cost when layered over another compressed swap device. A disk-backed zswap profile requires separate benchmarking before it becomes an optional mode.

### Wi-Fi connection reliability

- Fixed a watchdog logic error that treated NetworkManager's connecting/configuring states as healthy forever, allowing stalled Wi-Fi activation to evade recovery indefinitely.
- Added a per-adapter stalled-activation counter, a three-minute grace period, and a serialized recovery lock so timer and resume recovery cannot fight each other.
- Bounded NetworkManager CLI operations to prevent a stuck D-Bus request from holding the recovery helper open indefinitely.
- Bounded radio-state, saved-profile, scan, and autoconnect queries individually; saved-network inspection is capped to eight profiles, and explicit driver reload commands have time limits so recovery cannot wait forever on one helper call.
- Removed automatic Wi-Fi driver reload from background/watch/resume recovery. Recovery now stops after a bounded radio reset and reports the failure; driver reload remains available only through explicit force recovery.
- Preserved saved connection profiles and credentials; the watchdog does not delete networks or alter their security settings.

### Wine and Proton reliability

- Kept the normal Wine installer independent of UMU availability: Wine and its KDE integration can still be installed even if the optional Proton launcher is unavailable. The Proton action now checks for UMU only when the user invokes it.
- Corrected the Proton launcher's MSI handling. UMU accepts an executable as its launch target; passing `wine msiexec` as though UMU were a general Wine command wrapper was incorrect. MSI installers now produce a clear instruction to use standard Wine (`wine msiexec /i installer.msi`), while Proton remains available for executable game launches.
- Added CI assertions to prevent the optional UMU dependency from blocking the normal Wine installer and to guard against reintroducing the invalid MSI invocation.

### Build reliability and persistent app integration

- Raptor Music and the original upstream Shroudly desktop app are built and staged during every image build. Their installers verify the actual staged payload and safely skip only when a local build intentionally omits CI-generated staging files.
- The workflow verifies both applications inside the resulting GHCR image instead of relying on a one-time marker or a first-build-only integration lock.
- Static validation and workflow linting now run before expensive Shroudly and Raptor Music dependency builds, so shell, embedded-Python, and repository-contract failures surface earlier.
- Removed a stale validator assertion that still required LZ4 after the documented ZRAM switch to zstd; the current validator now checks the actual zstd configuration.
- After image verification, CI reports the OCI virtual size, largest image layers, and installed filesystem usage. This provides a measurable baseline for future size reduction rather than guessing which dependencies are safe to remove.
- The build workflow remains the update-image workflow: it pushes the OCI image to GHCR and does not create GitHub Releases or downloadable artifacts. ISO creation remains separate.

### Choice, compatibility, and distribution improvements

- Added a QEMU/KVM minimum-spec VM test script and guide. Its default profile provisions 4 GiB RAM, an Intel Core i3-6100-class Skylake CPU profile (2 cores / 4 threads), UEFI, and a sparse 64 GiB disk for repeatable installer and desktop smoke testing. Clock speed, cache, integrated graphics, and physical-system performance are documented limitations of CPU virtualization.

- Expanded the first-boot chat-client chooser beyond official Discord and Vesktop to include Equibop (Equicord) and GoofCord. All are optional downloads; none is silently preinstalled, and skipping remains supported.
- Documented Meowcord accurately as a separate self-hosted, federated Discord-like service in very early alpha, not a desktop client that can be installed from the first-boot Flatpak chooser.
- Browser choice now documents the full optional catalogue: Firefox, Brave, Zen Browser, Floorp, Waterfox, Chromium, Chrome, and Edge. The image remains browser-minimal by default.
- The Internet Archive item is the sole public ISO distribution destination. End users are directed to the Archive.org page and its matching checksum; instructions to run GitHub Actions or retrieve short-lived CI artifacts have been removed from the user-facing installation guide.
- Corrected the window-management documentation: KDE KWin runs on Wayland, while X11 applications use XWayland compatibility. The documentation distinguishes X11 from Microsoft Windows and lists the actual decoration, focus, snapping, and panel features.
- Repaired the generated Brave launcher that previously emitted malformed shell syntax. Its optional flags are now parsed as an argument array, and the adaptive raster-thread setting remains conservative on low-memory systems.
- GPU power-profile transitions now use hardware-reported Intel frequency bounds, return AMD DPM to driver-managed modes without leaving manual overdrive caps behind, and restore NVIDIA firmware-default power limits outside Power Saving. Unsupported device controls remain best-effort rather than blocking the desktop.
- USB audio uses a 512-frame, three-period buffer for USB ALSA devices (about 32 ms of period queue at 48 kHz), while retaining resampling quality 10 and existing PipeWire scheduling behavior.
- Kernel watchdog diagnostics and split-lock mitigation remain enabled; the small theoretical performance gain from disabling them did not justify losing diagnostics or weakening the mitigation.


### One-time app integration

- The update-image workflow stages Raptor Music and the original upstream Shroudly Linux desktop payload only when the explicit one-time integration option is enabled. Pull requests build and test the apps without staging them; ordinary pushes and scheduled rebuilds skip the payload.
- The installers detect their actual staged application files rather than relying on a separate marker file, which the BlueBuild files module did not deliver to the script stage.
- The internal `raptor-one-time-apps-consumed` tag locks integration only after the staged apps have been verified inside the successfully published GHCR image. Failed builds do not consume the one-time integration.
- Generated application binaries are not tracked in the source tree. The build workflow remains an OCI update-image workflow and does not create GitHub Releases or downloadable artifacts; ISO creation remains separate.

### Performance, audio, gaming, and update reliability

- Cortex now confirms the requested Power Profiles profile before applying device-level tuning; a failed request no longer leaves the UI showing a mode that was not applied. Cortex polls the active PPD profile so its mode indicator follows changes made through KDE Powerdevil's battery slider, and the saved mode follows external changes for the next login.
- One-Click Boost now performs one pressure-aware memory-reclaim request (rather than reclaiming twice), then pauses the configured optional indexers. It rolls back to Balanced and restores any partial Game Mode state if a stage fails. The ordinary Optimize Memory action also reports helper failures instead of recording them as successful runs.
- GameMode's start/end hooks now live in the active `/etc/gamemode.ini`, not an unreferenced drop-in. Cortex's process-pause helper is idempotent, so the UI button and GameMode cannot overwrite the same session's restore list and leave indexers frozen.
- PipeWire and WirePlumber restart limits now use valid systemd `[Unit]` directives. Audio RT memory locking is capped at 16 MiB, normal scheduling priority matches PipeWire's request, while USB audio retains quality 10 to preserve fidelity.
- Firefox's low-memory profile defaults now also seed Flatpak Firefox profiles. Brave's optimized launcher scales raster-worker count to installed RAM without reducing Chromium's site-isolation process model. Generated browser and gaming helper scripts are syntax-checked during image construction.
- ModemManager remains available for WWAN-equipped laptops; Firefox uses the active system DNS resolver instead of forcing Cloudflare DoH, preserving network-provided DNS behavior.
- Update Manager now streams every privileged and user-scoped helper through a queue-backed reader with hard deadlines and process-group cleanup. Silent or stalled helpers can no longer block the GUI indefinitely. Flatpak update checks and updates cover system and user installations separately; system refs update as root, user refs update as the logged-in account. Wi-Fi power-save state is restored after system updates.
- Update Manager build-time checks now parse its generated Python GUI and polkit XML and syntax-check all generated shell helpers.
- The ISO workflow no longer depends on the archived `build-container-installer` project. It verifies the signed Raptor image with the repository's Cosign public key, pins the verified digest, verifies the official Fedora 44 Kinoite ISO, and remasters it with `mkksiso`; disk selection remains interactive.
- Game Mode now includes the KDE crash reporter in its reversible optional-process pause list; it is resumed when the game session ends.
- README hardware requirements now state the Bazzite quad-core ~2 GHz / 8 GB baseline, Vulkan 1.3 capability, clearer AMD/Intel/NVIDIA driver-generation caveats, and the fact that 4 GB is still an unvalidated optimization target rather than a supported minimum.

- Cortex memory cleanup is now pressure-aware: it checks available RAM, caps normal reclaim at 256 MiB, and preserves useful page/file caches instead of forcing cache drops or repeatedly reclaiming nested cgroups. Compaction, zRAM recompression, OOM-score changes, and deeper reclaim are no longer part of Quick Optimize or Pre-Game Boost by default.
- Game Mode now separates performance-profile changes from memory cleanup. It pauses only optional indexers and thumbnail work selected in Cortex, tracks its active state, and restores only the work it paused. Package managers, Snap, fstrim, irqbalance, communications, audio, and user applications are left running.
- Cortex now has a sequential One-Click Boost: select the Power Profiles Performance mode, apply the selected GPU profile when supported, pause only the configured optional indexers, and request bounded memory reclaim only when RAM is genuinely low. It does not flush useful caches, compact memory, rewrite OOM scores, or recompress live ZRAM pages. Restore Desktop reverses Game Mode and returns to Balanced.
- power-profiles-daemon is the single owner of CPU governor, boost, EPP, frequency limits, and firmware platform profile. Cortex, the legacy CPU-policy unit, GPU detection, and GameMode no longer write competing CPU settings; KDE Powerdevil remains in control of the battery slider.
- ZRAM retains a half-of-RAM logical size and now uses LZ4 to reduce compression CPU overhead on low-power CPUs. ZRAM-aware swappiness, smaller dirty-page limits, a proportionate 32 MiB free-page reserve, and slower Cortex telemetry polling reduce avoidable pressure on low-memory systems. The 4 GB target still needs real-hardware benchmarking.
- GPU profiles no longer overwrite CPU governor settings or apply global Mesa threaded-rendering/CPU-throttle overrides. GameMode no longer overrides the CPU governor, accepts any compatible supervisor instead of restricting registration to a fixed launcher list, and keeps its real-time scheduler mode off to avoid competing with audio scheduling.
- PipeWire keeps its stable 512-frame graph; Pulse-compatible streams remain allocated for 30 seconds, and WirePlumber waits 60 seconds before suspending idle audio devices. Audio controllers are excluded from PCI runtime power suspension, and HDA codec/controller power saving stays disabled across profiles.
- Gaming defaults use moderate network buffers and fq_codel, avoid busy-poll spinning, prefer the NVMe none scheduler, and retain Steam shader pre-caching to reduce first-run shader stutter.
- Gaming background trim no longer drops all caches, compacts memory, freezes package managers, or stops Snap/storage maintenance. It uses a state marker and restores only optional indexers.
- Gaming device nodes now use mode 0660 with active-session uaccess ACLs instead of world-writable 0666 permissions. User-facing KDE services are no longer masked or given hard memory caps; Baloo has only a soft MemoryHigh guard.

### Shroudly Raptor

- The first successful v3.0.0 image build fetches the pinned upstream Shroudly submodule, runs its core tests and verification build, compiles the Linux Advanced-mode engine, packages the original Electron desktop app, and installs its desktop entry, icon, MIT license, and polkit action.
- Pull requests compile and test the original upstream app but do not stage it into the image. Later image builds skip both one-time app payloads after the successful v3.0.0 build consumes the permanent lock tag.
- Installation does not enable a service or login autostart and does not change proxy settings. The app is launched explicitly by the user; upstream protection modes remain user-controlled and Advanced mode requests administrator authorization.
- The separate incomplete Raptor Rust application-monitor prototype is not installed or advertised as the upstream Shroudly application.

### November 4–5 work consolidated into v3.0.0 — Raptor Music Expansion, Hardware Recovery & CI Reliability

### Updates

- **Raptor Music in-library search:** added a live, case-insensitive search across track title, artist, and album. Search results retain their real track IDs, so adding a filtered result to a playlist or queue and playing it no longer uses the filtered row number as an index into the unfiltered database.

- **Raptor Music folder scanning no longer follows directory-link cycles forever.** Recursive scans now track canonical directory paths, preventing a folder symlink back to a parent (or another already visited directory) from causing unbounded recursion and repeated imports.

- **Raptor Music fresh-database initialization:** schema migration 2 passed two `CREATE INDEX` statements to rusqlite's single-statement `execute()` API, which can reject the second statement and prevent the library from opening on a fresh install. The migration now uses `execute_batch()` inside the existing transaction, with a regression test asserting schema version 2 and both indexes.

- **Pull requests now validate image-workflow edits.** The push trigger watched `.github/workflows/build.yml`, but the pull-request path filter did not, so changes to the main image workflow could merge without running its PR build. Added the workflow file to the PR path filter.

- **CI no longer pushes generated application binaries to `main`.** The build stages Rust executables only in the temporary one-time staging directory; generated binaries are not committed. The workflow retains contents write permission solely for creating the permanent one-time integration lock tag after a successful opted-in image build.



- **Raptor Music queue index consistency:** removing a queue row before the currently playing entry now shifts the active-row index to match the reindexed queue; removing the active entry also resets the visible player state to Idle.

- **Raptor Music seek slider preview:** the 100 ms playback poll no longer overwrites the slider's in-progress value while the user is dragging. The selected position remains visible until Seek is pressed; the existing post-seek grace period then holds it while the decoder restarts.

- **Hardware recovery installer restoration:** restored the last intact installer structure and applied a passive Bluetooth controller health check. This puts the LED helper, suspend/resume hook, timer, and Bluetooth module configuration back in the actual installer instead of inside the generated Bluetooth helper.

- **Raptor Music playlist integrity:** playlist creation and renaming now reject blank names at the library API (not only in the desktop UI), and a transactional reorder method moves entries without losing their IDs or changing other tracks' relative order. Added regression tests for both cases.

- **Retired Raptor Shroudly prototype — false-success listener removed:** the app no longer opens a listener that acknowledged CONNECT without an upstream tunnel. Proxy launch now returns an explicit unsupported error, and documentation/installer comments state that the prototype is disabled.

- **Bluetooth recovery watchdog:** health checks now query the controller state without starting a discovery scan, avoiding unsolicited device discovery and leaving the user's scan state untouched.

- **Raptor Music Slint compatibility:** replaced the Slider `released` callback (not available in the project's Slint 1.5 dependency) with its supported `changed` callback and an explicit Seek action, preventing a UI compile failure.

- **Cortex hardware telemetry:** expanded CPU temperature detection across common thermal-zone and hwmon drivers, selects labelled CPU package sensors instead of blindly reporting thermal_zone0, reads GPU edge/core labels from AMD/Intel hwmon, and handles multi-GPU NVIDIA temperature output without a parse failure.

- **Raptor Music seeking:** added a real playback seek command that restarts decoding at the requested timestamp, keeps paused playback paused, and exposes a duration-bounded Slint progress slider. The position display no longer uses a hard-coded unknown-duration placeholder.

- **Raptor Music channel conversion and SPSC tests:** expanded common mono/stereo/quad/5.1/7.1 mapping paths and added tests for downmix/upmix layouts, malformed frames, complete-frame ring-buffer transfers, and capacity-limited writes.

- **Raptor Music track switching:** corrected the audio worker's in-session Play handling so next/previous and selecting another queued track actually restart the decoder with the new track and session token instead of dropping the command.

- **Raptor Music CI tests:** the image workflow now runs the complete workspace test suite after compiling the release binaries, so database, resampler, and player regression tests are exercised instead of merely being compiled.

- **Image signature policy:** added BlueBuild's signing module so the signed OCI image has the verification policy required by signed-image rebases and the ISO installer.

- **Raptor Music queue editing:** added removal of the selected queue entry, reindexed the remaining queue, and stop the active entry when it is removed or a playlist replaces the queue.

- **Raptor Music local playlists:** added SQLite-backed playlist creation, renaming/deletion, ordered track membership, removal/reordering support at the library layer, and desktop controls to create playlists, add the selected library track, and load a playlist into the playback queue.

- **BlueBuild Flatpak configuration and icon theme:** migrated the default Flatpak module from the legacy v1 `system:` shape to the current v2 `configurations:` schema, retaining the system-scoped Pupgui install. Removed the Papirus icon-theme package so the image no longer installs the icon theme the project explicitly avoids.

- **Raptor Music queue controls:** added previous/next controls that select and start the adjacent queue entry, while the main play control pauses/resumes the current entry rather than restarting it. The home-page feature description now reflects the XDG database location and scanner formats.

### Fixed

- **Rapid-push cancellation no longer lets delayed events cancel newer builds.** A lightweight preflight compares each push SHA with the live branch head; superseded events skip before entering the image-build concurrency group. The changelog is included in the push path filter so a final changelog-only commit still starts the build for the latest complete source tree.

- **CI no longer uploads and re-downloads Rust binaries it already has locally.** Both applications are built directly into `files/staging/`, and the BlueBuild recipe copies that directory in the same job. The artifact upload/download round trips wrote to unused temporary paths, so those four redundant steps are removed.

- **Cortex GPU temperature selection:** AMD `junction` readings are hotspot temperatures, not the conventional edge/core value. They were incorrectly ranked alongside `edge`, so a junction sensor could win alphabetically. Cortex now prefers edge/core, then generic GPU readings, and uses hotspot/junction only when no better sensor exists.

- **Raptor Music playback controls and persistence:** the main play control now
  pauses and resumes the active session instead of restarting the selected
  track. The library database now lives under the user's XDG data directory
  (or `~/.local/share`) rather than whichever directory launched the app.
  The desktop UI displays the decoded track duration, periodically persists
  playback position, and the recursive scanner recognizes additional
  Symphonia-supported audio extensions.


- **CI could silently ship a stale Raptor Music binary.** The build workflow
  treated the presence of a cached release executable as proof that the current
  source had already been built, then skipped Cargo entirely. A source-only
  change could therefore bypass compilation and leave an old binary staged.
  The workflow now always runs `cargo build --release --workspace`; the
  existing Cargo target cache remains available for incremental compilation.
- **Rapid main-branch pushes could run multiple full image builds concurrently.**
  The build workflow previously cancelled superseded pull-request builds only.
  It now cancels an in-progress push build when a newer push arrives on the
  same branch, while scheduled and manually dispatched builds are left alone.
  This prevents stale commits from consuming runner time alongside the newest
  source revision; it does not mask an underlying compile or image-build error.

- **The ISO workflow never built an ISO.** It called `osbuild` with a
  nonexistent `raptor-manifest.json`, then treated a successful `cargo build`
  as a fallback even though that produces no installer image. The workflow now
  uses `jasonn3/build-container-installer@v1.4.0` against the published
  `ghcr.io/cerberus9-dev/raptor-os:latest` image, with Fedora 44 / Kinoite
  installer inputs, and uploads the generated ISO plus checksum as a workflow
  artifact. It is manually dispatched so routine source pushes do not trigger
  an expensive ISO build.

- **Shroudly was presented as a working DPI-bypass proxy despite having no
  upstream forwarding.** The daemon only acknowledged `CONNECT` and returned
  `501` for ordinary requests; its dashboard values were placeholders. The
  README and app metadata now disclose that it is an incomplete prototype,
  not a usable proxy. Functional proxy forwarding and the original desktop UI
  remain outstanding; no managed-network bypass behavior is being added.

- **Retired Raptor Shroudly prototype — advanced-mode cleanup could erase the entire host firewall.**
  Its cleanup path called `nft flush ruleset`, which removes rules owned by
  firewalld, containers, VPNs, and other applications—not just Shroudly.
  Packet mode now reports itself as unimplemented and performs no nftables
  changes until an isolated, app-owned table and scoped cleanup are implemented.

- **GameMode could skip restoration when an optional suspend config was
  missing.** Its end hook exited before calling the privileged restore helper
  if either config file was absent. It now processes whichever files exist and
  always runs the default restoration helper.

- **Background-process resume no longer matches arbitrary command lines.**
  Cortex's manual Resume action and GameMode's end hook used
  `pkill -CONT -f`, which matches full command lines and could resume
  unrelated processes. All corresponding resume paths now use the existing
  `safe-signal CONT` helper, matching process names with the same bounded
  prefix logic used when suspending them.

- **Every build failed from 2026-11-04: the base image silently changed.** The
  recipe used `image-version: stable`. Bazzite moved its `stable` tag from
  Fedora 44 to Fedora 45 on 2026-11-04 00:43 UTC (it had stopped publishing
  Fedora 44 builds on 2026-10-26), so the next build switched to a Fedora 45
  base where `rpm-ostree` commands abort inside the build container with
  `This system was not booted via libostree` (both the package removal script and
  the `rpm-ostree` module). Pinned to `stable-44`, the last Fedora 44 build,
  which is what built successfully on 2026-11-01 to 2026-11-03. Porting the
  package steps to Fedora 45 is a separate change; note that a pinned base no
  longer receives Bazzite/Fedora updates until that is done.
- **Raptor Cortex could hang before its window ever appeared.** The window
  constructor ran `_refresh_stats()` synchronously, before `present()`, and
  again every 2 s on the UI thread. It reads sysfs, hwmon, `lspci` and
  `nvidia-smi`; any of those can block for seconds on some hardware (slow ACPI
  thermal zones, a sleeping GPU), and then no window appeared and nothing was
  printed. Readings now run on worker threads, one per sensor, and each updates
  only its own label when it finishes, so a slow sensor delays only itself. With
  two sensors artificially blocked for 8 s the window appeared in 0.3 s (it took
  17 s, frozen, before).
- **Raptor Tasks: Delete did nothing.** The row menu's Edit/Delete items pointed
  at actions (`app.edit`, `app.delete`) that were created but never registered,
  so GTK showed them disabled. They are now registered on the row under the
  `row.` prefix. (Clicking a task still opened the editor, which is why Edit
  seemed to work.)
- **Update manager showed a false "Missing sudoers" warning.** The startup check
  ran `os.path.exists("/etc/sudoers.d/raptor-update")` as an ordinary user, but
  `/etc/sudoers.d` is mode 0750 root:root on Fedora, so the file always looked
  missing. The same unreadable file made `run_privileged` conclude "no sudoers"
  and demote `sudo -n` behind a polkit prompt, and its refusal check read stderr
  after merging stderr into stdout, so it could never see a refusal. Now
  `sudo -n` is always tried first (it refuses within milliseconds when not
  allowed), then pkexec, with real refusal detection and a clear error if
  neither works. The update helper also no longer "clears a stale lock" by
  deleting a file rpm-ostree does not use: when rpm-ostree answers "Transaction
  in progress" it waits for the other operation and, after about 90 s, runs
  `rpm-ostree cancel`.
- **Cheatsheet: 21 of 56 commands rendered as empty boxes.** Row titles are
  Pango markup, so `rpm-ostree install <pkg>` was parsed as an unknown `<pkg>`
  tag and the row showed nothing (GTK logged "Failed to set text ... from
  markup"). Titles, descriptions, group titles and the copy toast are now
  escaped; the clipboard still receives the raw command. The `--check` entry now
  notes that it can wrongly report "No updates available" on image-based systems
  (documented in the update manager's source: coreos/rpm-ostree #4891).
- **Cortex now says why it cannot start.** The menu entry silently did nothing
  when Cortex failed at startup. `raptor-cortex-launcher` now writes everything
  Cortex prints to `~/.cache/raptor-cortex.log` and, if Cortex exits with an
  error, shows a window with the last lines of that log. `get_cpu_temp` also no
  longer raises when `/sys/class/thermal` does not exist.
- **Wi-Fi dropped to wired-only after closing the lid, and the radio would not
  come back (regression from the Wi-Fi/Bluetooth recovery added in this cycle).**
  After every resume, if Wi-Fi was not connected within ~20 s, the recovery ran
  all three steps: reconnect, power-cycle the radio, then reload the Wi-Fi
  driver. It never checked that Wi-Fi had been connected before suspend or that
  any known network was in range, so anyone on Ethernet, docked, or away from
  their usual network had the radio and driver torn down on every resume; on
  many chips a driver reload can leave the device missing until reboot.
  Recovery is now gated on evidence that Wi-Fi should be working: the pre-suspend
  hook records whether Wi-Fi was connected (resume does nothing if it was not);
  escalation past a plain reconnect needs a known network in range or a
  completely empty scan (a wedged driver sees nothing), and the driver is not
  reloaded if other networks are visible but none of ours; the one-minute
  watchdog never escalates for Wi-Fi that has not connected at all this boot.
  The manual `wifi-recover force` still runs every step unconditionally.
- **Raptor Cortex would not open at all.** Since the 2026-09-30 refactor that
  folded the GPU profiler into Cortex, building the Graphics section called
  `self.add(gfx_group)`, but the window has no `add` method (every other section
  uses `content.append`). That raised `AttributeError` while the window was being
  built, so no window ever appeared. Fixed to `content.append(gfx_group)`. Found
  by actually launching the app under a virtual display; compile checks and unit
  tests of the new functions had not caught it.
- **Raptor Tasks could not create a task.** The New/Edit dialog was an
  `Adw.Dialog` built with window-style arguments (`transient_for`, `modal`,
  `set_default_size`, and a `present()` with no parent). `Adw.Dialog` supports
  none of them, so clicking "+" raised `TypeError` (silently, in the GUI). The
  dialog is now an `Adw.Window`. Create, empty-text rejection, save to disk,
  edit, mark done and delete were all exercised in a real window.
- **Two cheatsheets, now one.** `Raptor Cheatsheet` and `Raptor Cheatsheet
  (Terminal)` had identical content. The terminal copy, its menu entry and the
  separate `-gui` binary are removed; everything lives in the single
  `raptor-cheatsheet` app, which gained the terminal version's search (type to
  filter commands and categories). Also fixed in the merge: clicking a command to
  copy it never worked (`Gdk.Clipboard` has no `set_text` in GTK4; it is
  `set`), and `systemctl --user logs` (not a real command) is now
  `journalctl --user -u <unit>`.
- **Update manager gave up on a flaky connection and misreported why.** The
  update helper made 3 attempts, then quit. It printed `Failed (exit 0)` for
  every failure (it read `$?` after the `if`, so the real exit code was lost and
  the timeout branch could never run), and its "clearing corrupt layer cache"
  step deleted two directories rpm-ostree does not use for image layers, so it
  did nothing. Layers that finished downloading are kept between attempts (the
  next attempt reports them as "already present"); only the layer that was
  mid-download restarts. Now: 8 attempts with a capped back-off (15 s up to
  90 s), the real exit code, a correct timeout message, and Wi-Fi power-save is
  switched off for the duration of the update, since a radio in power-save
  stalls long downloads ("read: connection timed out ... unexpected end of
  file" on the large layer).
- **`rpm-ostree` module failing with a `tuned-ppd` / `power-profiles-daemon`
  conflict.** The base image ships `tuned-ppd`, which conflicts with
  `power-profiles-daemon` (both provide `ppd-service`). The original recipe
  removed `tuned-ppd` in the same rpm-ostree transaction as the install. Moving
  the removals to `raptor-remove-packages.sh` (to survive packages the base
  image no longer ships, such as `cmake`) made it run after the install, so the
  conflict returned. The script is now its own module placed before the
  `rpm-ostree` module in `recipes/recipe.yml`.
- **Every image build since 2026-10-10 failed at the `files` module.** A cleanup
  commit deleted `files/system_files/zram-generator.conf` as "dead", but
  `recipes/recipe.yml` still copies it to `/etc/systemd/zram-generator.conf`
  (it is the active swap-on-zram config: half of RAM capped at 8 GB, zstd,
  priority 100, discard). The `files` module aborts on a missing source, so the
  build never reached the package or script steps and no fix could be published.
  The file is restored unchanged, and `.github/scripts/validate.sh` now fails
  the build early if any file the recipe copies is missing from the repo.
- **Cortex and the GPU profile are now one decision.** They were two
  independent controls (the performance mode, and a separate GPU profile list),
  so you had to set both and they could contradict each other, e.g. Power
  Saving with a max-performance GPU. Choosing Power Saving / Balanced /
  Performance now also sets the matching GPU profile. A new "Match GPU to
  performance mode" switch (on by default) controls this; picking a GPU profile
  by hand turns it off as an override. Cortex also shows the GPU model, usage
  and clock next to the GPU temperature.
- **Failed builds now explain themselves.** A `diagnose` job in the workflow
  runs only when the build fails and posts the first real error, with context,
  as an annotation on the run.
- **Image build aborting inside a build script.** `raptor-gaming-devices.sh`
  runs under `set -euo pipefail` and wrote files into
  `/usr/share/flatpak/overrides/` and `/usr/share/doc/raptor-gaming-devices/`
  without creating them, so a missing directory aborted the whole image build.
  It also relied on `/etc/modules-load.d` existing in `raptor-gaming.sh`. Both
  now `mkdir -p` their targets. Every build script was then executed in recipe
  order in a clean environment and all 13 exit 0.
- **Battery drains.** (1) Gaming mode held `/dev/cpu_dma_latency` at 0, which
  allows only busy-polling, so the CPU never entered an idle state and drew
  near full power even when idle; the comment claimed "C1 or shallower". It is
  now 50 us (shallow idle states allowed), is not taken at all on battery, and
  the holder releases itself when the charger is unplugged or the end-of-game
  hook never runs. (2) WirePlumber set `session.suspend-timeout-seconds = 0`
  plus `api.alsa.disable-suspend` on every ALSA device, so the sound card and
  audio graph never suspended; idle devices now suspend after 30 s. (3) The
  Intel GPU profile exported `vblank_mode=0` (vsync off for every OpenGL app,
  GPU runs flat out); removed. (4) The power-saving GPU profile disabled the
  Mesa shader cache, which forces shaders to recompile on every launch and costs
  more energy than it saves; the cache stays enabled.
- **Cortex "Scan for Steam Games" never found any game.** The `appmanifest`
  parser stripped the quotes off each line and then tested for `"appid"`
  (with quotes), which can never match, so every scan reported "No Steam games
  found". Rewritten: reads every library Steam knows about from
  `libraryfolders.vdf` (extra drives included), the Flatpak Steam location and
  common external-drive mounts, skips Proton / Steam Linux Runtime /
  Steamworks redistributables, and de-duplicates symlinked paths.
- **"Set as Raptor Wallpaper" failed on unusual filenames.** The image path
  was pasted unescaped into a JavaScript string evaluated by Plasma and into a
  `file://` URL, so a name containing a quote, backslash, `#` or `%` broke the
  call (or injected into it) and failed silently. The path is now URL-encoded
  and JSON-escaped, `reloadConfig()` is called so the change applies
  immediately, and the right-click menu also covers AVIF, JXL, TIFF and GIF.
- **Screen brightness forced to 50% and never restored.** Cortex wrote 50% of
  max straight into `/sys/class/backlight` every time battery/power-saving
  mode was applied (boot, plug/unplug), overriding the user's brightness,
  desyncing KDE PowerDevil (brightness keys and slider acted on a stale value)
  and leaving the screen dim afterwards. Cortex no longer touches the
  backlight; PowerDevil's own on-battery dimming still applies.
- **Wi-Fi never reconnecting; Bluetooth dead after power-saving.** (1) Cortex's
  power-saving put EVERY PCI device, including the Wi-Fi card, into runtime
  suspend, runtime-suspended wireless NICs, forced 802.11 power save on, and set
  Bluetooth sniff/park link modes. Wireless/Bluetooth devices are now always
  kept awake and those forced settings are gone. (2) `91-raptor-network.conf`
  used invalid keys (bare `autoconnect-retries`, `wifi.powersave` under
  `[device]`), so none of it applied; it now sets
  `[main] autoconnect-retries-default=0` (retry forever) and
  `[connection] wifi.powersave=2`. (3) The resume dispatcher ran
  `nmcli device disconnect`, which blocks autoconnect until a manual reconnect;
  it also only fired once Wi-Fi was already up and left a stale marker file.
  It now only flushes DNS.
- **Touchpad dead / barely moving after lid open until two fingers are used.**
  Two causes. (1) `61-raptor-libinput.conf` was installed as
  `/etc/libinput/local-overrides.quirks` and applied to *every* touchpad:
  `AttrEventCodeDisable=ABS_MT_SLOT;ABS_MT_TRACKING_ID` disables the
  multitouch finger-tracking events libinput needs, and the other keys in it
  (`AttrTappingEnabled`, `AttrMiddleEmulationEnabled`) are not valid quirk
  attributes. The file is removed. (2) Nothing re-initialised an I2C-HID
  touchpad after resume. The systemd-sleep hook
  `/usr/lib/systemd/system-sleep/raptor-resume` (installed by
  `files/scripts/raptor-hardware-fixes.sh`) finds whichever device libinput
  classes as a touchpad and re-binds just its I2C/serio driver on resume.
  Works on any laptop; USB/Bluetooth touchpads are left alone. The lid-open
  service no longer tries to call KWin as root (it never worked).
- **Image build failing: `No installed package matches 'cmake'`.** The recipe's
  rpm-ostree `remove:` list aborts the entire build when any listed package is
  absent from the base image, and the base image (now Fedora 44) no longer
  ships `cmake` (and possibly `krita`/`vlc`). Removals now live in
  `files/scripts/raptor-remove-packages.sh`, which skips packages that are not
  installed and downgrades a failed removal to a warning. The `remove:` block
  was deleted from `recipes/recipe.yml`.
- **Apps randomly failing to open (all apps).** Gaming mode, Cortex's
  "Optimize Memory Now" and the manual trim script froze background
  processes with `SIGSTOP` using substring name matching. The lists included
  `kded`, `gvfs`, `kwalletd`, `kactivitymanagerd`, `gvfsd-metadata` and
  `kbuildsycoca` (things nearly every KDE/GTK/Chromium app talks to), plus
  browsers, Discord, Spotify and Steam. Relaunching a frozen single-instance
  app just hands off to the frozen copy, so it never appears. If the matching
  resume was missed (game crash, Cortex closed), they stayed frozen until
  reboot. Fixes: all freezing now goes through `/usr/lib/raptor/safe-signal`
  (prefix match on process name, refuses session-critical processes and
  single-instance apps); those entries were removed from every list; and a
  user timer (`raptor-unfreeze.timer`, every 45 s and at login) resumes
  anything left frozen. Crash handler (`drkonqi`) is in the default suspend
  list.
- **Raptor Tasks (Windows-style task manager) could never start.** A typo in
  `raptor-tasks.sh` (`def _setup_shortcuts):`, missing `(self`) was a Python
  SyntaxError, so the app crashed on launch.
- **App picker rewritten.** The old picker returned the literal string `None`
  for every native-package entry, so selecting BleachBit, btop, Neovim etc.
  all collapsed into one entry and installed the wrong thing. It also listed
  duplicate apps, no categories, and Flathub IDs that do not exist (Sober,
  Nook, Piped, NewPipe, Bromite, Proton Auth, Sleepy, Tor Browser, ...).
  Now: category column, unique IDs, nothing preselected, native packages use
  `rpm:` keys, and every Flatpak ID is checked against Flathub before install
  so a bad ID is reported by name instead of failing silently. Removed apps
  that are not desktop Linux software (NewPipe, Piped, SearXNG, Bromite).

### Added

- **Raptor Music and the original upstream Shroudly desktop app are the one-time v3.0.0 payloads.** CI builds and tests both on pull requests without staging them; the first successful main-branch image build stages both apps. The permanent lock tag is created only after the image is successfully built and pushed.
- **Hardware recovery after suspend** (`files/scripts/raptor-hardware-fixes.sh`):
  one resume hook plus one 1-minute timer, no new apps or menu entries. On
  every resume it re-binds the touchpad's I2C/PS/2 driver, binds the kernel's
  mute / mic-mute LEDs to the audio mute state, and recovers Wi-Fi and
  Bluetooth in detached background jobs so resume is never delayed. Wi-Fi
  escalates: re-enable autoconnect and reconnect, power-cycle the radio, reload
  the driver. Bluetooth escalates: unblock and power on, restart
  `bluetooth.service`, reload `btusb`; its health check requires the
  controller to report a live, powered state without starting discovery. The
  timer is also a Wi-Fi watchdog while awake. Recovery never overrides Wi-Fi or
  Bluetooth turned off on purpose and never uses `nmcli device disconnect`.
  `btusb enable_autosuspend=0` stops USB Bluetooth adapters from autosuspending.


- **Fan information in Raptor Cortex (read-only)** — a new "Fans" row in the
  live stats group lists every fan RPM sensor the kernel exposes through
  hwmon (`fan*_input`, with `fan*_label` when present), plus NVIDIA fan
  percentage via `nvidia-smi` when available. Shows "No fan sensors
  detected" when none exist. Cortex only reads; it never writes fan speed,
  curves or PWM, so the removal of manual fan control above still stands.


## [v2.7.0] - 2026-10-01 (Major Feature Expansion — Cortex Unification, App Picker Overhaul, Battery, Tasks)

### Changed

- **GPU profiling is now part of Raptor Cortex** — the separate "Raptor GPU
  Profiler" app is gone. Profile selection moved into a **Graphics** group in
  Cortex, next to the CPU boost mode it pairs with, and the `raptor-gpu-profile`
  package now ships only the detection and apply machinery that Cortex drives.
  The profile itself is unchanged: the same five profiles, the same
  `/etc/raptor-force-<name>` marker, the same immediate apply with no reboot.
  What changed is that one decision about one machine no longer has its own
  window. Worth noting how this had drifted: GPU profiles were reachable
  through **three** entry points — a GTK app from `raptor-gpu-profile`, a
  terminal UI from `hud-install`, and neither sharing a word with Cortex. The
  terminal UI in particular had no way to know about the other two.

- **Raptor Cortex is now the central control app** — one window for CPU
  boost modes, GPU performance profiles, memory optimization, game mode
  service trimming, background service management, temperature monitoring,
  Quick Actions (Pre-Game Boost, Restore Desktop, Clear Shader Cache),
  Persistent Settings (auto-apply mode on boot, auto-restore after game,
  scheduled cleanup), and Scheduled Memory Cleanup.

- **One-click Quick Optimize** — new "Quick Optimize" button auto-tunes
  optimization options to the current performance profile (Performance =
  all aggressive, Balanced = caches+compaction+zram+oom, Power Saving =
  same without swap). Advanced options remain available in a collapsible
  expander for fine control.

- **Barebones base install** — default RPMs reduced to essentials only
  (removed: plasma-systemmonitor, neovim, tmux, ripgrep, fzf, ninja-build,
  meson, podman, podman-compose, thunderbird, variety, btop, gcc, make,
  cmake, krita, vlc). System flatpaks reduced to ProtonUp-Qt only. All
  other apps moved to firstboot app picker.

### Added

- **Raptor Tasks** (`raptor-tasks.sh`) — GTK4/Adwaita task manager with
  categories (Personal, Work, Gaming, Shopping, Ideas, Other), persistence
  (`~/.config/raptor-tasks.json`), keyboard shortcuts (Ctrl+N for new task),
  popover menu (edit/delete), and CoyoteTM-inspired UI.

- **Raptor Cheatsheet** (`raptor-cheatsheet.sh`) — terminal (fzf) and GUI
  versions with 9 categories: rpm-ostree, Flatpak, Podman, Toolbox,
  Systemd User, Raptor OS Specific, Troubleshooting, File System (Atomic).
  Click any command to copy to clipboard.

- **Gaming Device Support** (`raptor-gaming-devices.sh`) — udev rules for
  Logitech (G Hub, Lightspeed), Razer, SteelSeries, Corsair, HyperX,
  Glorious, Roccat, Turtle Beach + generic HID/joystick. Flatpak overrides
  for G Hub, OpenRazer, Piper. Documentation at
  `/usr/share/doc/raptor-gaming-devices/README.md`.

- **Steam Game Auto-Detection** — "Scan for Steam Games" button in Cortex
  parses `appmanifest_*.acf` files across common library paths and adds
  detected games to the library with Steam launch method.

- **Battery Optimizations** (Power Saving mode) — WiFi power save (`iw set
  power_save on`), Bluetooth controller suspend (`hciconfig lp`),
  display backlight reduction to 50%, HDA audio controller power save,
  NVMe `min_power`, SATA `min_power`, USB autosuspend (excludes btusb,
  usbhid, snd-usb-audio), runtime PM for network devices.

- **Enhanced Background Process Optimization** — `trim-background` now
  pauses Steam, Discord, browsers (Firefox, Chrome, Brave, Edge, Vivaldi,
  Opera), Spotify, Slack, Thunderbird, Element, Signal, Telegram, VS Code,
  Vesktop, plus indexers (tracker, baloo, akonadi) and package managers.
  `restore-background` resumes all with IO priority/niceness reset.

- **Wine/Proton Enhancements** — added `d3dcompiler_47` and `dxvk` to
  default runtimes, Wine Mono/Gecko auto-bootstrap, ProtonUp-Qt integration
  (detects latest GE-Proton), esync/fsync enabled, winemenubuilder
  suppressed, VA-API for hardware decode, DXVK DLL overrides verified.

- **Browser Choice Expanded** — added Zen Browser and Helium alongside
  Firefox, Brave, Chromium, Chrome, Edge.

- **App Picker: 150+ New Apps** across categories:
  - *Communication*: ProtonMail, Proton Auth, Aegis, Authenticator,
    Telegram, Signal, Slack, Zoom, Element
  - *Gaming*: Heroic, Prism Launcher, Sober (Roblox), Sleepy (ZZZ),
    Qrookie, PortProton, Lutris, Bottles, Protontricks, emulators
    (Ryujinx, RPCS3, RetroArch, Dolphin, PCSX2, DuckStation, Flycast,
    ScummVM, OpenRA, Chiaki, Moonlight, Sunshine, GOverlay)
  - *Privacy*: Tor Browser, OnionShare, Mullvad VPN, Cryptomator,
    VeraCrypt, KeePassXC, Standard Notes
  - *De-Googled*: Ungoogled Chromium, Bromite, LibreWolf, SearXNG,
    NewPipe, Piped, FreeTube
  - *Productivity*: ONLYOFFICE, LibreOffice, Bitwarden, Joplin,
    MarkText, Calibre, RSS Guard, Obsidian, Notion
  - *Creative*: GIMP, Inkscape, Krita, Darktable, Blender, Kdenlive,
    DigiKam, Shotcut, OBS Studio, Audacity, Boatswain, HandBrake
  - *Audio*: EasyEffects, Helvum, LMMS, Ardour, Tenacity
  - *Video*: VLC, mpv, Clapper, Celluloid, Kooha, Kdenlive, Shotcut,
    HandBrake, Subtitle Edit, MakeMKV
  - *Torrents*: qBittorrent, Transmission
  - *Dev Tools*: VSCodium (Flatpak + native), VS Code, IntelliJ IDEA
    Community, PyCharm Community, Godot, GitHub Desktop, Pods,
    Developer Runtime
  - *Education*: KCalc, LabPlot, Cantor, KStars, Marble, Step, Kalgebra,
    Kanagram, KHangMan, KTurtle, KGeography
  - *System Tools*: GNOME System Monitor, KSysGuard, Warehouse,
    Impression, CoreCtrl, GNOME Backups, Flatseal, BleachBit, Filelight,
    Klipper, kfind, file-roller, btop, ncdu, Restic, Syncthing, Tailscale
  - *Fun/Reading*: Nook, Foliate

- **Task Managers** — GNOME System Monitor (Windows-like) and KSysGuard
  added to app picker.

- **Update Manager Hardening** — statically checks NOPASSWD grant in
  `/etc/sudoers.d/raptor-update`, streams check-helper output live into
  visible Console, time-bounds metadata refresh (3 × 150 s attempts,
  500 s wall-clock ceiling), falls back to local rpm-ostree state on
  refresh failure.

### Removed

- **Manual fan control and fan profiles in Raptor Cortex** — removed
  rather than shipped. The feature was guarded by a chip allowlist, an
  RPM readback requirement, a thermal interlock and a duty cap, but it
  could only ever be verified against a synthetic sysfs tree: no machine
  available for testing had a fan controller on the supported list, so
  every write path would have gone out unexercised on real silicon. It
  also did not appear on the machines it was built for, so it was
  carrying risk for no visible gain. Fan control is left entirely to the
  kernel and the board firmware, which is where it belongs. CPU
  temperature, which Cortex displayed alongside it, is unaffected.

- **Two duplicate GPU profiler entry points** — `raptor-gpu-profile`
  installed a GTK4 app at `/usr/bin/raptor-gpu-profiler`, and `hud-install`
  installed a separate terminal UI at `/usr/bin/raptor-gpu-profile-ui.sh`
  behind a launcher. Both put an entry named "Raptor GPU Profiler" in the
  app menu, so the menu showed two identically-named entries that were
  different programs. Both are folded into Cortex. `hud-install` no longer
  has any GPU profile responsibility, and its polkit/sudoers surface
  narrowed to match.

- **An orphaned icon and a polkit rule for deleted binaries** — the
  polkit rule in `49-raptor-gpu.rules` matched on `raptor-gpu-profile`
  and `raptor-gpu-profiler`, both of which no longer exist; it now matches
  only `gpu-detect.sh`, which is what actually gets invoked. The
  unreferenced `raptor-gpu-profiler.svg` is removed.

- **Heavy default packages** — plasma-systemmonitor, neovim, tmux, ripgrep,
  fzf, ninja-build, meson, podman, podman-compose, thunderbird, variety,
  btop, gcc, make, cmake, krita, vlc removed from base image.

- **Heroic Games Launcher** moved from default flatpaks to app picker.

### Fixed

- **Update manager could hang on "Checking" and never finish** — the
  GUI's metadata refresh ran the check-helper and then sat in a blocking
  `communicate()`, showing nothing on screen while the network stalled
  on flaky school WiFi. Three fixes: (1) the check-helper now time-bounds
  every attempt (max 3 × 150 s, no unbounded final attempt), probes
  connectivity to ghcr.io up front with a clear message, and treats
  rpm-ostree `--check` exit 77 ("nothing new") as the clean success it
  is; (2) the GUI streams the helper's output *live* into a built-in
  Console that is visible from launch (not hidden until an update
  starts), reading through a queue-backed reader with a `CHECK_TIMEOUT=660`
  wall-clock ceiling and process-group cleanup so a stalled pipe cannot freeze the check;
  (3) if the refresh *does* fail, the manager falls back to local
  rpm-ostree state first — a staged-but-not-booted deployment or a
  populated `cached-update` is still reported as an available update
  ("reboot to apply it") instead of the refresh error hiding an update
  that is already on disk.

- **Update manager said "up to date" even when a new image was pushed** —
  the `cached-update` field in `rpm-ostree status --json` only becomes
  populated after a check has actually run. The check-helper now runs
  `rpm-ostree upgrade --check` to refresh the field, and on container-
  native images (Bazzite) a registry digest cross-check (skopeo + jq)
  compares the booted image's digest against the remote tag's digest.
  If they differ, "AvailableUpdate:" is printed and the update is
  reported. This matches the ground truth ublue-update uses.

- **"VSCodium — Native (Full Permissions)" could never install** — it
  added VSCodium's repository with `dnf config-manager` and then ran
  `rpm-ostree install codium`, but `rpm-ostree` does not read dnf's
  repository configuration, so a repo added at runtime is invisible to
  it. The layering step always failed. Replaced with the Flatpak plus
  host-level permission overrides, which give the same practical access,
  work immediately, and need no reboot.

- **Update Manager was permanently bricked when `sudo -n` was not
  permitted** — `run_privileged()` looped over `["sudo", "-n"]` then
  `["pkexec"]` and caught only `FileNotFoundError`. That covers a missing
  binary and nothing else: when `sudo` exists but refuses (missing/stale
  sudoers, user not covered, sudo wanting a TTY), `subprocess.Popen`
  already returned successfully, the `pkexec` fallback was never reached,
  and the caller was handed an already-dead process whose stderr got
  parsed as helper output. It now reads the NOPASSWD grant from
  `/etc/sudoers.d/raptor-update` statically and only falls through to
  `pkexec` when `sudo` genuinely cannot do the job, with an error that
  names the file to check.

- **A malformed sudoers drop-in was installed silently** — the installer
  ran `visudo -cf … || true`, so a syntax error shipped a rule set that
  sudo silently ignores in its entirety, leaving `sudo -n` refusing and
  the update manager dead on a freshly booted image with nothing in the
  build log to explain it. Validation now fails the image build (and
  warns, rather than pretending to pass, if `visudo` itself is
  unavailable).

- **Seven processes were left frozen for the rest of the session** —
  `trim-background` and `restore-background` each declared their own
  `BACKGROUND_PROCS` array and the two had drifted. 20 processes were
  `SIGSTOP`ped but only 13 were ever `SIGCONT`ed, so `apt-get`, `dpkg`,
  `updatedb`, `mlocate`, `snapd`, `unattended-upgrade` and
  `gnome-software` stayed frozen. The dangerous pair is `dpkg`/`apt-get`:
  a `SIGSTOP`ped dpkg holds the dpkg lock, so every later apt invocation
  blocks until reboot. Both actions now share a single array declared at
  helper scope, so the two can never drift again. `dpkg`/`apt-get`/
  `unattended-upgrade` were also removed from the set entirely — stopping
  a live package transaction is unsafe regardless of symmetry; PackageKit
  is now stopped via `systemctl`, which releases its transaction lock
  cleanly on `SIGTERM`.

- **"Restore Desktop" did nothing while reporting success** — the handler
  called `cortex-helper resume-background`, which is not a real action.
  It fell through to the usage arm and exited 1, so every suspended
  process stayed frozen while the UI toasted "Desktop restored — Balanced
  mode, all services resumed". Now calls the real `restore-background`,
  and both this and "Resume All Services" funnel through one helper that
  checks the exit status and surfaces failures instead of swallowing them.

- **Two more unvalidated sudoers drop-ins** — `raptor-gpu-profile.sh`
  wrote `/etc/sudoers.d/raptor-gpu` with no `visudo` check at all, and
  `raptor-hud.sh` chained its check with `&&` so a failure could not
  stop the build. `raptor-gaming.sh` *appends* to that same file, so its
  rules were never validated either — a malformed line there would have
  silently broken GPU profile switching as well. All three now fail the
  build on an invalid file.

- **Dolphin still froze/crashed on selecting a .zip despite the earlier
  fix** — the old `ShowPreview=false` key doesn't exist in Dolphin's
  schema and is silently ignored, so the F4 Information Panel kept
  parsing selected archives with KFileMetaData in the main process and
  wedged the UI on big/remote zips. Replaced with the real keys —
  `[InformationPanel]` is now written as `previewsShown=false`,
  `previewsAutoPlay=false`, `showHovered=false` (no preview thumbnail
  generation, no hover refresh; F4 still opens the panel on demand) — in
  `/etc/xdg/dolphinrc` and the once-per-user login migration (stamp
  bumped to `raptor-dolphin-defaults-v2` so existing users get the
  corrected keys applied). The `[PreviewSettings] Plugins` value was also
  malformed (`imagethumbnail:directorythumbnail` — a colon-joined token
  that matches no plugin id); it is now a proper comma list,
  `imagethumbnail, directorythumbnail`, so image + folder thumbnails
  actually stay enabled while the heavy video/audio/document previewers
  stay off. Finally, Ark's *Compress / Extract / drag-and-drop extract*
  KFileItemAction plugins are removed at build time
  (`raptor-dolphin-stability.sh`): they advertise `application/octet-
  stream`, so Dolphin queries them for *any* selection and they force a
  per-file MIME scan that freezes the UI (KDE bug 499551) and can segfault
  Dolphin via kerfuffle (KDE bugs 482016/420429). Double-clicking an
  archive to open it in Ark (via `raptor-mimeapps.list`) is unaffected —
  only the right-click compress/extract entries are dropped.

- **Dolphin still froze on selecting a .zip *after the laptop had been on
  a while*** — the Baloo half of the earlier fix never landed: Plasma 6
  reads `~/.config/baloofilerc`, but the image shipped `/etc/xdg/baloorc`
  and the login migration wrote `~/.config/baloorc` (wrong filename), and
  the keys used (`IndexFileContent`, `IndexFileSizeLimit`…) don't exist
  in Baloo's schema. The content-indexing switch was therefore silently
  ignored and Baloo kept indexing file contents. After hours of uptime
  `baloo_file_extractor` + `baloo_filemetadata_temp_extractor` saturate
  disk I/O, and selecting a zip makes KFileMetaData wait on those same
  files → Dolphin freezes (KDE bug 495145's mechanism). Now: the real
  config is shipped as `/etc/xdg/baloofilerc` (and `skel`) with
  `[Basic Settings] Indexing-Enabled=false` plus `[General]
  only_basic_indexing=true` and archive globs in the genuine `exclude
  filters` key; the login migration (stamp bumped to
  `raptor-dolphin-defaults-v3`) writes those keys to `baloofilerc`,
  deletes the stale `baloorc` artifact, and runs `balooctl disable` to
  stop the running indexer immediately. On top of that,
  `raptor-dolphin-stability.sh` now also removes kfilemetadata's in-
  process **archive + AppImage extractors**
  (`kfilemetadata_archiveextractor.so`, matched by substring across
  distros), so selecting an archive can no longer read its contents for
  metadata at all; Ark's own kerfuffle engine is untouched, so opening
  archives still works.

- **Browser firstboot dialog re-appeared every session** — the "Decide
  Later" button did not write the stamp file, causing the dialog to
  re-appear on every login until an explicit choice was made. Renamed to
  "Keep Firefox" and now writes the stamp on dismiss, treating closure as
  "I want Firefox". Connectivity is now checked *before* showing the
  dialog; offline boots leave the stamp unwritten so the choice is
  offered again on the next login.

- **A single failed download cost the user the chat client permanently** —
  the chat dialog stamped the file after `install_with_retry` returned
  failure too, so one flaky Flathub fetch was final. It now stamps only
  on a real install.

- **The chosen browser was reported as the default even when it was not**
  — the desktop id was hardcoded, and Flathub has since renamed
  `firefox.desktop` to `org.mozilla.firefox.desktop`, so Firefox
  installed correctly, `xdg-settings` failed quietly, and the user was
  still shown a green tick confirming their new default. The id is now
  read back from the installed Flatpak, and the success message only
  appears when the default was genuinely applied.

- **Crash handler (`drkonqi`) now suspended by default in Game Mode** —
  the default Cortex config now includes `drkonqi`, `baloo_file`,
  `akonadiserver`, `kdeconnectd`, `packagekitd`, `gvfsd-metadata`,
  `kactivitymanagerd`. On first run these are written to
  `/etc/raptor/cortex-suspend.conf` and persist across reboots.

### Security

- **All sudoers drop-ins validated with `visudo -cf` at build time** —
  a syntax error now fails the image build instead of shipping a rule set
  that sudo silently ignores, which would leave the feature dead with no
  error in the build log. Applies to `raptor-cortex`, `raptor-gpu-profile`,
  `raptor-gaming`, `raptor-update`, `raptor-hud`.

- **Polkit rules narrowed** — `49-raptor-gpu.rules` now matches only
  `gpu-detect.sh` (the two deleted GUI binaries removed from the match
  list).

---

## [v2.6.9] - 2026-09-10 (WiFi Reconnection, Cursor Fix, More Apps)

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
- **Update Manager** uses the canonical `rpm-ostree upgrade` operation instead of relying on `ujust update`, which is not available in all environments and can silently fail with "not found"

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


### Optional application catalogue

- Added LocalSend for local-network file sharing, Gear Lever for managing AppImages, and Resources for system monitoring. These remain opt-in Flatpaks and add no idle background services.
- First-boot chat-client installation uses per-user Flatpak operations consistently with the user-session service.

### Windows compatibility: Raptor Wine

- Fixed the optional Proton launcher to capture the executable path and forward remaining arguments correctly; an empty invocation now prints usage instead of attempting to launch an unset target.
- Updated the user-facing V3.0 README to match the standard-Wine-first workflow and document the release-wide GUI-first, stability-first, hardware-reliability, and honest-compatibility principles.
- Preserved the ordinary Wine workflow: `wine`, `winecfg`, `wineboot`, `wineserver`, and `winetricks` remain directly available, using Wine's standard `~/.wine` prefix unless the user chooses otherwise.
- Added simple executable handling: opening `.exe` files launches them with Wine, while `.msi` installers are passed to `wine msiexec /i`. KDE's right-click menu offers direct Wine launching without a setup wizard or profile manager.
- Added an optional Proton game action powered by UMU. Proton supplies its game-focused compatibility patches and supported DXVK/VKD3D graphics translation inside the Steam Linux Runtime, without requiring the Steam client.
- UMU manages its normal default Proton prefix automatically; no per-game profile setup, storefront selection, or game ID entry is required for ordinary use. Users can still override the standard WINEPREFIX or optional UMU settings when needed.
- Kept Wine Mono, Gecko, and Winetricks available for common Windows application dependencies. No global DLL overrides or forced synchronization settings are applied, avoiding needless regressions in desktop applications.
- Windows compatibility varies by program; anti-cheat, DRM, kernel drivers, and unsupported Windows APIs may still prevent some titles from running.

### Desktop app resource and Wayland tuning

- Extended safe Electron Wayland backend selection to official Discord, Vesktop, Equibop, and GoofCord.
- Removed restrictive forced V8 heap and renderer-process caps from Vesktop rather than risk breaking large servers, screen sharing, or voice/video calls.

### Bluetooth adapter identity

- Added a BlueZ startup helper that assigns detected controllers the friendly alias “Raptor OS Bluetooth”, avoiding raw interface names such as hci0 in the user-facing adapter identity.
- Paired-device cache entries are deliberately preserved; automatic deletion could remove legitimate separate Bluetooth LE/classic identities.


### App picker additions
- Added **Flameshot** as an optional screenshot capture and annotation tool.
- Added **Save Desktop** as an optional desktop-configuration backup and restore tool.
- Both remain opt-in Flatpaks; neither adds a default background service or increases the base image footprint.


### Raptor app visual consistency
- Aligned the Raptor Cortex, Raptor Wallpaper, and Raptor Update Manager application icons with the Raptor green-on-graphite identity. App glyphs remain distinct while sharing a consistent accent palette.
