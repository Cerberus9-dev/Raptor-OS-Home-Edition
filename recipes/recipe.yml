#!/bin/bash
# raptor-app-choice.sh
# First-boot optional-app selection dialog.
# v2.0: fixed declare -A, user stamp path, Wayland-safe (no DISPLAY requirement),
#       additive-only (does NOT re-offer apps already installed by default).
#
# Runs as a user service (raptor-firstboot.service) after plasma-plasmashell.
# Stamp at ~/.local/share/raptor/app-choice-done prevents re-running.

set -euo pipefail

STAMP_FILE="${HOME}/.local/share/raptor/app-choice-done"
LOG_TAG="raptor-app-choice"

log() { logger -t "${LOG_TAG}" -- "$*"; }
err() { logger -t "${LOG_TAG}" -p user.err -- "$*"; }

# ── Guard ─────────────────────────────────────────────────────────────────────
if [[ -f "${STAMP_FILE}" ]]; then
    log "App selection already done — skipping."
    exit 0
fi

# ── Prerequisite check ────────────────────────────────────────────────────────
if ! command -v zenity &>/dev/null; then
    err "zenity not found — cannot show app dialog. Writing stamp to avoid loop."
    mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"
    exit 0
fi

if ! command -v flatpak &>/dev/null; then
    err "flatpak not found — cannot install optional apps. Writing stamp to avoid loop."
    mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"
    exit 0
fi

# ── Per-user app configuration ─────────────────────────────────────────────────
# Runs unconditionally — even if the user clicks Skip on the app selection
# dialog below. Handles anything that must live in per-user directories and
# therefore can't be set at image build time (Flatpak user data, ~/.mozilla).
# Previously lived in raptor-appconfig.sh + raptor-appconfig.service; merged
# here to eliminate redundant files and service units.

# Vesktop: write Chromium flags.txt to cap V8 heap and force Wayland-native
VESKTOP_CFG="${HOME}/.var/app/dev.vencord.Vesktop/config/vesktop"
if flatpak info dev.vencord.Vesktop &>/dev/null 2>&1; then
    mkdir -p "${VESKTOP_CFG}"
    cat > "${VESKTOP_CFG}/flags.txt" << 'VESKTOPFLAGS'
# Raptor OS: Vesktop Chromium flags
# Caps memory and forces Wayland-native rendering (avoids ~30 MB XWayland overhead).

--ozone-platform=wayland
--enable-wayland-ime

# V8 old-gen heap: 256 MB (default ~1.4 GB on systems with free RAM)
--max-old-space-size=256
--js-flags=--max-old-space-size=256

# Max 2 renderer processes (~80-120 MB each)
--renderer-process-limit=2

# Share renderer processes across same-site origins
--process-per-site

# Reduce CPU/memory for occluded/background windows
--disable-backgrounding-occluded-windows
--disable-renderer-backgrounding

# Signal allocator to apply more aggressive GC pressure
--memory-model=low

# VA-API hardware video decode (reduces CPU load in video calls/streams)
--enable-features=VaapiVideoDecoder,VaapiVideoEncoder
--disable-features=UseChromeOSDirectVideoDecoder,CrashpadWithBrowserLock
VESKTOPFLAGS

    # Belt-and-suspenders: also set via flatpak user override (env vars are
    # picked up even if the flags.txt path ever changes between Vesktop versions)
    flatpak override --user dev.vencord.Vesktop \
        --env=OZONE_PLATFORM=wayland \
        --env=ELECTRON_OZONE_PLATFORM_HINT=auto \
        2>/dev/null || true
    log "Vesktop: flags.txt and user Flatpak override applied."
else
    log "Vesktop not installed — skipping Vesktop config."
fi

# Firefox: copy skel user.js to any existing profiles that don't have one yet.
# policies.json (system-wide, from raptor-gaming.sh) handles memory defaults;
# user.js covers GPU compositing, rendering quality, and privacy prefs.
FF_SKEL="/etc/skel/.mozilla/firefox/raptor-default/user.js"
if [[ -f "${FF_SKEL}" ]]; then
    for profdir in \
        "${HOME}/.mozilla/firefox/"*.default        \
        "${HOME}/.mozilla/firefox/"*.default-release \
        "${HOME}/.mozilla/firefox/"*.default-esr;
    do
        [[ -d "${profdir}" ]] || continue
        if [[ ! -f "${profdir}/user.js" ]]; then
            cp "${FF_SKEL}" "${profdir}/user.js"
            log "Firefox user.js deployed to: $(basename "${profdir}")"
        fi
    done
fi

# Flatpak: ensure the user-level Flathub remote exists so app installs below work.
if command -v flatpak &>/dev/null; then
    flatpak remote-add --user --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
fi

# ── App catalogue ─────────────────────────────────────────────────────────────
# Format: "PRESELECT|DISPLAY_NAME|FLATPAK_ID|DESCRIPTION"
# Only list apps NOT already installed by the default Flatpak list in recipe.yml.
# Mandatory defaults (Heroic, ProtonUp, Firefox, Nautilus) — bare basics only.
# Vesktop moved to raptor-chat-choice.sh; VSCodium, VLC, Flatseal, Mission
# Center, BleachBit, Filelight, and qbittorrent all moved here (optional).
# are never shown here — they are always installed.
APP_CATALOGUE=(
    # ── Communication ──────────────────────────────────────────────────────
    "FALSE|Telegram|org.telegram.desktop|Fast, secure messaging"
    "FALSE|Signal|org.signal.Signal|Private, encrypted messaging"
    "FALSE|Slack|com.slack.Slack|Team communication"
    "FALSE|Zoom|us.zoom.Zoom|Video conferencing"
    "FALSE|Element|im.riot.Riot|Matrix chat client — decentralised, encrypted messaging"
    # ── Productivity ───────────────────────────────────────────────────────
    "FALSE|ONLYOFFICE|org.onlyoffice.desktopeditors|Office suite — Word/Excel/PowerPoint compat"
    "FALSE|Bitwarden|com.bitwarden.desktop|Open-source password manager"
    "FALSE|Joplin|net.cozic.joplin_desktop|Note-taking app with markdown support"
    "FALSE|MarkText|com.github.marktext.marktext|Clean markdown editor"
    "FALSE|Calibre|com.calibre_ebook.calibre|Ebook library manager"
    # ── Office ────────────────────────────────────────────────────────────
    "FALSE|LibreOffice|org.libreoffice.LibreOffice|Full office suite — Writer, Calc, Impress"
    # ── Creative ───────────────────────────────────────────────────────────
    "FALSE|GIMP|org.gimp.GIMP|Photo editing and image manipulation"
    "FALSE|Inkscape|org.inkscape.Inkscape|Vector graphics editor"
    "FALSE|Krita|org.kde.krita|Digital painting and illustration"
    "FALSE|Darktable|org.darktable.Darktable|RAW photo development and editing"
    "FALSE|Blender|org.blender.Blender|3D modelling, animation, rendering"
    "FALSE|Kdenlive|org.kde.kdenlive|Non-linear video editor (KDE)"
    "FALSE|Shotcut|org.shotcut.Shotcut|Video editor (non-linear)"
    "FALSE|OBS Studio|com.obsproject.Studio|Screen recording and live streaming"
    "FALSE|Audacity|org.audacityteam.Audacity|Audio recording and editing"
    "FALSE|Boatswain|com.feaneron.Boatswain|Elgato Stream Deck controller"
    "FALSE|HandBrake|fr.handbrake.ghb|Video transcoder — convert, compress, and re-encode video files"
    # ── Development ────────────────────────────────────────────────────────
    "FALSE|VSCodium|com.vscodium.codium|Open-source VS Code build, no telemetry (Flatpak — sandboxed)"
    "FALSE|VSCodium — Native (Full Permissions)|RPM:vscodium|Native RPM install (NOT sandboxed) — full system access for tray, pkexec/admin tools, and scripts that need to touch the system. Requires a reboot after first-boot."
    "FALSE|VSCodium Insiders|com.vscodium.codium-insiders|Daily pre-release build, no telemetry (Flatpak — sandboxed)"
    "FALSE|VSCodium Insiders — Native (Full Permissions)|RPM:vscodium-insiders|Native RPM install of the pre-release build (NOT sandboxed). Requires a reboot after first-boot."
    "FALSE|Developer Runtime|None|Git + Node.js + pip — for running dev tools and scripts (install via: sudo rpm-ostree install git nodejs python3-pip)"
    "FALSE|Godot Engine|org.godotengine.Godot|Free, open-source game engine"
    "FALSE|GitHub Desktop|io.github.shiftey.Desktop|Git GUI for GitHub repos"
    "FALSE|Pods|com.github.marhkb.Pods|Podman/Docker container GUI"
    # ── Gaming & Media ─────────────────────────────────────────────────────
    "FALSE|Bottles|com.usebottles.bottles|Run Windows apps and games via Wine/DXVK — isolated per-bottle environments"
    "FALSE|Lutris|net.lutris.Lutris|Game launcher for Linux, Wine, emulators"
    "FALSE|Protontricks|com.github.Matoking.protontricks|Configure Steam/Proton games — install DirectX, runtimes, VC++, etc."
    "FALSE|Spotify|com.spotify.Client|Music and podcast streaming"
    "FALSE|Plex|tv.plex.PlexDesktop|Media server desktop client"
    "FALSE|VLC|org.videolan.VLC|Plays virtually any media format/codec — previously a default install, mpv is the built-in lightweight player"
    # ── Audio ──────────────────────────────────────────────────────────────
    "FALSE|EasyEffects|com.github.wwmm.easyeffects|Headset EQ, bass boost, noise reduction via PipeWire"
    # ── System tools ───────────────────────────────────────────────────────
    "FALSE|Warehouse|io.github.flattool.Warehouse|Browse, manage and clean up installed Flatpak apps"
    "FALSE|Impression|io.gitlab.adhami3310.Impression|Flash OS images to USB drives"
    "FALSE|CoreCtrl|org.corectrl.CoreCtrl|AMD GPU and CPU control — overclocking, fan curves, power limits"
    "FALSE|GNOME Backups|org.gnome.DejaDup|Automatic encrypted backups of your home folder"
    "FALSE|Mission Center|io.missioncenter.MissionCenter|GPU/CPU/RAM monitor — Cortex now covers live stats, but this gives a fuller system view"
    "FALSE|Flatseal|com.github.tchx84.Flatseal|Flatpak permission manager — previously a default install"
    "FALSE|BleachBit|None|Deep system/cache cleanup tool (install via: sudo rpm-ostree install bleachbit)"
    "FALSE|Filelight|None|Visual disk usage analyser (install via: sudo rpm-ostree install filelight)"
    "FALSE|Klipper|None|Clipboard manager — keeps history of copied text (install via: sudo rpm-ostree install klipper)"
    "FALSE|kfind|None|KDE file search tool — find files by name, type, size, date (install via: sudo rpm-ostree install kfind)"
    "FALSE|file-roller|None|Archive manager — extract and create .zip, .tar.gz, .7z, and more (install via: sudo rpm-ostree install file-roller)"
    # ── Communication ──────────────────────────────────────────────────────
    "FALSE|Thunderbird|org.mozilla.Thunderbird|Email and calendar client"
    # ── Terminal & Developer tools ─────────────────────────────────────────
    "FALSE|btop|None|System resource monitor (install via: sudo rpm-ostree install btop)"
    "FALSE|GitHub CLI (gh)|None|GitHub CLI tool (install via: sudo rpm-ostree install gh)"
    "FALSE|Variety|None|Wallpaper manager (install via: sudo rpm-ostree install variety)"
    "FALSE|GCC + Make + CMake|None|C/C++ compiler toolchain — for compiling game mods, tools, or custom builds"
    "FALSE|Ninja + Meson|None|Modern build systems used by Mesa, Wine, and many open-source projects"
    "FALSE|Neovim|None|Terminal text editor with plugin ecosystem (install via: sudo rpm-ostree install neovim)"
    "FALSE|dash|None|Fast POSIX shell — lightweight alternative to bash for running scripts (install via: sudo rpm-ostree install dash)"
    "FALSE|xclip|None|Clipboard CLI tool — copy/paste from the terminal (install via: sudo rpm-ostree install xclip)"
    "FALSE|ksshaskpass|None|KDE SSH password prompt — GUI dialog for SSH key passphrases (install via: sudo rpm-ostree install ksshaskpass)"
    "FALSE|libssh-tools|None|SSH utilities — ssh-keygen, ssh-agent, and related tools (install via: sudo rpm-ostree install libssh-tools)"
    # ── Media & Downloads ──────────────────────────────────────────────────
    "FALSE|Parabolic|org.nickvision.tubeconverter|Download YouTube and other online videos"
    "FALSE|Kooha|io.github.seadve.Kooha|Simple screen recorder (no OBS needed for basic capture)"
    "FALSE|Clapper|com.github.rafostar.Clapper|Lightweight video player (GPU-accelerated)"
    "FALSE|Amberol|io.bassi.Amberol|Simple music player"
    "FALSE|qBittorrent|None|Torrent client — previously a default install (install via: sudo rpm-ostree install qbittorrent)"
    # ── Utilities ──────────────────────────────────────────────────────────
    "FALSE|Metadata Cleaner|fr.romainvigier.MetadataCleaner|Remove metadata from files before sharing"
    "FALSE|Flatsweep|io.github.gmodena.flatsweep|Clean up leftover Flatpak app data"
    "FALSE|Warp|app.drey.Warp|Fast local file transfer between devices"
    "FALSE|Upscayl|org.upscayl.Upscayl|AI image upscaling (doubles image resolution)"
    # ── Virtualisation ────────────────────────────────────────────────────
    "FALSE|GNOME Boxes|org.gnome.Boxes|Simple VM manager — run Windows or other Linux in a window"
    # ── Privacy & Security ─────────────────────────────────────────────────
    "FALSE|ProtonVPN|com.protonvpn.www|Privacy-first VPN from the makers of ProtonMail"
    "FALSE|KeePassXC|org.keepassxc.KeePassXC|Offline password manager — no cloud required"
    # ── Entertainment & Media ──────────────────────────────────────────────
    "FALSE|FreeTube|io.freetubeapp.FreeTube|YouTube client with no ads and no tracking"
    # ── Note-taking ────────────────────────────────────────────────────────
    "FALSE|Obsidian|md.obsidian.Obsidian|Markdown note-taking with linked notes (second brain)"
    # ── Gaming ────────────────────────────────────────────────────────────
    "FALSE|Cartridges|page.kramo.Cartridges|Game library that aggregates Steam, Heroic, Bottles and more"
    "FALSE|Ryujinx|org.ryujinx.Ryujinx|Nintendo Switch emulator"
    "FALSE|RPCS3|net.rpcs3.RPCS3|PlayStation 3 emulator"
    "FALSE|RetroArch|org.libretro.RetroArch|Multi-system emulator frontend (SNES, N64, PS1, GBA and many more)"
    "FALSE|Dolphin Emulator|org.DolphinEmu.dolphin-emu|GameCube and Wii emulator"
    "FALSE|PCSX2|net.pcsx2.PCSX2|PlayStation 2 emulator"
    "FALSE|Chiaki|re.chiaki.Chiaki4deck|Remote play client for PlayStation 4 and 5"
    # ── Audio Production ──────────────────────────────────────────────────
    "FALSE|Helvum|org.freedesktop.Helvum|PipeWire patchbay — visually connect audio/MIDI devices"
    "FALSE|LMMS|io.lmms.LMMS|Music production — beats, melodies, samples"
    "FALSE|Ardour|org.ardour.Ardour|Professional audio workstation (recording, mixing, mastering)"
)

# ── Build zenity argument list ────────────────────────────────────────────────
ZENITY_ARGS=()
for entry in "${APP_CATALOGUE[@]}"; do
    IFS='|' read -r preselect name id desc <<< "${entry}"
    ZENITY_ARGS+=("${preselect}" "${name}" "${id}" "${desc}")
done

# ── Show dialog ───────────────────────────────────────────────────────────────
SELECTED=$(
    zenity \
        --list \
        --title="Raptor OS — Optional App Setup" \
        --text="<b>Select optional applications to install:</b>\n\nTick anything you want, or click <b>Skip — Install Nothing</b> to install none of these now.\nMost apps install from Flathub. Items marked 'Native (Full Permissions)' install as system RPMs — they are NOT sandboxed (full system access) and need a reboot to activate.\nEverything here can also be installed later from Discover or the terminal." \
        --checklist \
        --column="Install" \
        --column="Application" \
        --column="Flatpak ID" \
        --column="Description" \
        --print-column="3" \
        --separator="|" \
        "${ZENITY_ARGS[@]}" \
        --width=700 --height=600 \
        --ok-label="Install Selected" \
        --cancel-label="Skip — Install Nothing" \
        2>/dev/null
) || true
# zenity exits 1 on "Skip" — that's caught by `|| true`

# ── Always write stamp so we never loop ───────────────────────────────────────
mkdir -p "$(dirname "${STAMP_FILE}")"
touch "${STAMP_FILE}"

if [[ -z "${SELECTED:-}" ]]; then
    log "App selection skipped or nothing selected."
    exit 0
fi

log "User selected Flatpak IDs: ${SELECTED}"

# ── Install selected Flatpaks ─────────────────────────────────────────────────
# declare -A is required for associative arrays — this was missing before.
declare -A ID_TO_NAME
for entry in "${APP_CATALOGUE[@]}"; do
    IFS='|' read -r _pre name id _desc <<< "${entry}"
    ID_TO_NAME["${id}"]="${name}"
done

FAILED=()
NEEDS_REBOOT=0
IFS='|' read -ra TO_INSTALL <<< "${SELECTED}"

for flatpak_id in "${TO_INSTALL[@]}"; do
    flatpak_id="${flatpak_id//\"/}"   # strip stray quotes zenity may add
    [[ -z "${flatpak_id}" ]] && continue

    app_name="${ID_TO_NAME[${flatpak_id}]:-${flatpak_id}}"
    log "Installing ${app_name} (${flatpak_id})…"

    if [[ "${flatpak_id}" == RPM:* ]]; then
        # Native (non-Flatpak), full-permissions RPM install from a third-party
        # repo. The package is named after the colon (e.g. RPM:vscodium -> codium).
        NEEDS_REBOOT=1
        RPM_PKG="${flatpak_id#RPM:}"
        case "${RPM_PKG}" in
            vscodium|vscodium-insiders)
                # Add VSCodium's official DNF repo, then layer the matching codium RPM.
                if ! command -v dnf config-manager &>/dev/null; then
                    err "dnf config-manager not available — cannot add VSCodium repo."
                    FAILED+=("${app_name}")
                    continue
                fi
                if ! sudo dnf config-manager addrepo \
                        --id=VSCodium \
                        --set=name=VSCodium \
                        --set=baseurl=https://paulcarroty.gitlab.io/vscodium-deb-rpm-repo/rpms/ \
                        --set=enabled=1 \
                        --set=gpgcheck=1 \
                        --set=gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
                        --set=repo_gpgcheck=1 \
                        --set=metadata_expire=1h \
                        >> /tmp/raptor-app-install.log 2>&1; then
                    err "Failed to add VSCodium repository."
                    FAILED+=("${app_name}")
                    continue
                fi
                # Translate our catalogue token into the actual VSCodium RPM name:
                # vscodium -> codium, vscodium-insiders -> codium-insiders
                case "${RPM_PKG}" in
                    vscodium)           RPM_NAME="codium" ;;
                    vscodium-insiders)  RPM_NAME="codium-insiders" ;;
                    *)                  RPM_NAME="${RPM_PKG}" ;;
                esac
                if sudo rpm-ostree install --idempotent --allow-inactive "${RPM_NAME}" \
                        >> /tmp/raptor-app-install.log 2>&1; then
                    log "OK (rpm-ostree): ${app_name} — REBOOT required to activate"
                else
                    err "${app_name}: install after reboot: sudo rpm-ostree install ${RPM_NAME}"
                    FAILED+=("${app_name}")
                fi
                ;;
            *)
                if sudo rpm-ostree install --idempotent --allow-inactive "${RPM_PKG}" \
                        >> /tmp/raptor-app-install.log 2>&1; then
                    log "OK (rpm-ostree): ${app_name} — REBOOT required to activate"
                else
                    err "${app_name}: install after reboot: sudo rpm-ostree install ${RPM_PKG}"
                    FAILED+=("${app_name}")
                fi
                ;;
        esac
    elif [ "${flatpak_id}" = "None" ]; then
        # RPM-only app — attempt via rpm-ostree
        # Handle compound entries like "GCC + Make + CMake"
        case "${app_name}" in
            "GCC + Make + CMake")
                APP_LOWER="gcc make cmake";;
            "Ninja + Meson")
                APP_LOWER="ninja-build meson";;
            "GitHub CLI (gh)")
                APP_LOWER="gh";;
            "Developer Runtime")
                APP_LOWER="git nodejs python3-pip";;
            *)
                APP_LOWER="${app_name,,}";;
        esac
        if sudo rpm-ostree install --idempotent --allow-inactive $APP_LOWER \
                >> /tmp/raptor-app-install.log 2>&1; then
            NEEDS_REBOOT=1
            log "OK (rpm-ostree): ${app_name}"
        else
            err "Note: ${app_name} — install after reboot: sudo rpm-ostree install ${APP_LOWER}"
            FAILED+=("${app_name}")
        fi
    elif flatpak install -y --noninteractive flathub "${flatpak_id}" \
            >> /tmp/raptor-app-install.log 2>&1; then
        log "OK: ${app_name}"
    else
        err "FAILED: ${app_name} (${flatpak_id})"
        FAILED+=("${app_name}")
    fi
done

# ── Result dialog ─────────────────────────────────────────────────────────────
if [[ ${#FAILED[@]} -eq 0 ]]; then
    if [[ "${NEEDS_REBOOT}" -eq 1 ]]; then
        zenity --info \
            --title="Raptor OS — Setup Complete" \
            --text="All selected applications were installed successfully.\n\nSome were installed as native system apps and will be available after a reboot." \
            --width=380 2>/dev/null || true
    else
        zenity --info \
            --title="Raptor OS — Setup Complete" \
            --text="All selected applications were installed successfully." \
            --width=340 2>/dev/null || true
    fi
else
    FAIL_LIST=$(printf '  • %s\n' "${FAILED[@]}")
    if [[ "${NEEDS_REBOOT}" -eq 1 ]]; then
        REBOOT_NOTE="\n\nSome system apps staged successfully and will appear after a reboot."
    else
        REBOOT_NOTE=""
    fi
    zenity --warning \
        --title="Some Apps Failed to Install" \
        --text="The following could not be installed:\n\n${FAIL_LIST}${REBOOT_NOTE}\n\nCheck your connection and install them later from Discover." \
        --width=400 2>/dev/null || true
fi

log "App selection complete."
