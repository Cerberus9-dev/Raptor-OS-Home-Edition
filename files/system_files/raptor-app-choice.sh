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
# Format: "CATEGORY|NAME|ID|DESCRIPTION"      (nothing is pre-selected)
#   ID is either a Flathub app ID, or "rpm:<pkg> [pkg...]" for native packages
#   layered with rpm-ostree. ID is the unique key — no duplicates allowed.
# Every Flatpak ID is re-checked against Flathub at install time
# (flatpak remote-info), so a wrong or delisted ID is reported by name instead
# of silently breaking the batch.
# Not listed here because the base image already ships them: Ark, KCalc, mpv,
# Protontricks, ProtonUp-Qt, Wine, Steam.
# Browsers live in raptor-browser-choice.sh; Vesktop in raptor-chat-choice.sh.
APP_CATALOGUE=(
    # Communication
    "Communication|Telegram|org.telegram.desktop|Fast, secure messaging"
    "Communication|Signal|org.signal.Signal|Private, end-to-end encrypted messaging"
    "Communication|Element (Matrix)|im.riot.Riot|Decentralised, encrypted chat"
    "Communication|Discord|com.discordapp.Discord|Official Discord client"
    "Communication|Slack|com.slack.Slack|Team communication"
    "Communication|Zoom|us.zoom.Zoom|Video conferencing"
    "Communication|Pidgin|im.pidgin.Pidgin|Classic multi-protocol chat (XMPP, IRC and more)"
    "Communication|Mumble|info.mumble.Mumble|Low-latency open-source voice chat (VoIP)"
    "Communication|Jami|net.jami.Jami|Peer-to-peer calls and chat, no central server"
    "Communication|Fractal|org.gnome.Fractal|Matrix client for GNOME"
    "Communication|Thunderbird|org.mozilla.Thunderbird|Email and calendar"
    "Communication|Proton Mail Bridge|ch.protonmail.protonmail-bridge|Use Proton Mail in Thunderbird and other mail apps"
    # Productivity
    "Productivity|LibreOffice|org.libreoffice.LibreOffice|Full office suite - Writer, Calc, Impress"
    "Productivity|ONLYOFFICE|org.onlyoffice.desktopeditors|Office suite with strong Word/Excel/PowerPoint compatibility"
    "Productivity|Planify|io.github.alainm23.planify|Task and project manager"
    "Productivity|Errands|io.github.mrvladus.List|Simple to-do list"
    "Productivity|Super Productivity|com.super_productivity.SuperProductivity|To-do list with time tracking and Pomodoro"
    "Productivity|Joplin|net.cozic.joplin_desktop|Markdown notes with sync"
    "Productivity|Obsidian|md.obsidian.Obsidian|Linked markdown notes"
    "Productivity|Standard Notes|org.standardnotes.standardnotes|End-to-end encrypted notes"
    "Productivity|MarkText|com.github.marktext.marktext|Clean markdown editor"
    "Productivity|Zotero|org.zotero.Zotero|Research reference manager"
    "Productivity|Okular|org.kde.okular|PDF and document viewer with annotations"
    "Productivity|RSS Guard|io.github.martinrotter.rssguard|RSS/Atom feed reader"
    # Passwords & Authenticators
    "Passwords & 2FA|Bitwarden|com.bitwarden.desktop|Open-source password manager"
    "Passwords & 2FA|KeePassXC|org.keepassxc.KeePassXC|Offline password manager, no cloud needed"
    "Passwords & 2FA|Proton Pass|me.proton.Pass|Proton's password manager"
    "Passwords & 2FA|Authenticator|com.belmoussaoui.Authenticator|Two-factor (TOTP) code generator"
    # Privacy & Security
    "Privacy & Security|Tor Browser|org.torproject.torbrowser-launcher|Anonymity network browser, reaches .onion sites"
    "Privacy & Security|Mullvad Browser|net.mullvad.MullvadBrowser|Tor-Browser-based browser without Tor, anti-fingerprinting"
    "Privacy & Security|OnionShare|org.onionshare.OnionShare|Anonymous file sharing over Tor"
    "Privacy & Security|Proton VPN|com.protonvpn.www|Privacy-first VPN"
    "Privacy & Security|Cryptomator|org.cryptomator.Cryptomator|Encrypt files before uploading to the cloud"
    "Privacy & Security|Metadata Cleaner|fr.romainvigier.MetadataCleaner|Strip metadata from files before sharing"
    # De-Googled
    "De-Googled|LibreWolf|io.gitlab.librewolf-community|Hardened Firefox fork"
    "De-Googled|Ungoogled Chromium|io.github.ungoogled_software.ungoogled_chromium|Chromium with Google services removed"
    "De-Googled|FreeTube|io.freetubeapp.FreeTube|YouTube client with no ads or tracking"
    "De-Googled|Organic Maps|app.organicmaps.desktop|Offline OpenStreetMap maps"
    "De-Googled|Nextcloud|com.nextcloud.desktopclient.nextcloud|Self-hosted cloud storage sync client"
    # Graphics
    "Graphics|GIMP|org.gimp.GIMP|Photo editing"
    "Graphics|Krita|org.kde.krita|Digital painting"
    "Graphics|Inkscape|org.inkscape.Inkscape|Vector graphics"
    "Graphics|Darktable|org.darktable.Darktable|RAW photo development"
    "Graphics|digiKam|org.kde.digikam|Photo library manager"
    "Graphics|Blender|org.blender.Blender|3D modelling, animation, rendering"
    "Graphics|Pinta|com.github.PintaProject.Pinta|Simple Paint-style image editor"
    "Graphics|Drawing|com.github.maoschanz.drawing|Basic drawing app"
    "Graphics|Upscayl|org.upscayl.Upscayl|AI image upscaling"
    # Video & Streaming
    "Video & Streaming|OBS Studio|com.obsproject.Studio|Recording and live streaming - high-end"
    "Video & Streaming|Kooha|io.github.seadve.Kooha|Simple screen recorder - low-end friendly"
    "Video & Streaming|Boatswain|com.feaneron.Boatswain|Control Elgato Stream Deck"
    "Video & Streaming|Kdenlive|org.kde.kdenlive|Video editor"
    "Video & Streaming|Shotcut|org.shotcut.Shotcut|Lightweight video editor"
    "Video & Streaming|HandBrake|fr.handbrake.ghb|Video transcoder"
    "Video & Streaming|Parabolic|org.nickvision.tubeconverter|Download videos from YouTube, Instagram and many other sites"
    "Video & Streaming|MakeMKV|com.makemkv.MakeMKV|Rip Blu-ray and DVD discs"
    # Audio & Media Players
    "Audio & Players|VLC|org.videolan.VLC|Plays almost anything"
    "Audio & Players|Celluloid|io.github.celluloid_player.Celluloid|GTK frontend for mpv"
    "Audio & Players|Clapper|com.github.rafostar.Clapper|Modern lightweight video player"
    "Audio & Players|Strawberry|org.strawberrymusicplayer.strawberry|Music library player"
    "Audio & Players|Amberol|io.bassi.Amberol|Simple music player"
    "Audio & Players|Spotify|com.spotify.Client|Music streaming"
    "Audio & Players|Plex|tv.plex.PlexDesktop|Plex desktop client"
    "Audio & Players|Audacity|org.audacityteam.Audacity|Audio recording and editing"
    "Audio & Players|LMMS|io.lmms.LMMS|Music production"
    "Audio & Players|Ardour|org.ardour.Ardour|Professional audio workstation"
    "Audio & Players|EasyEffects|com.github.wwmm.easyeffects|EQ, bass boost and noise reduction"
    "Audio & Players|Helvum|org.pipewire.Helvum|PipeWire audio patchbay"
    # Game Launchers & Compatibility
    "Gaming|Heroic Games Launcher|com.heroicgameslauncher.hgl|Epic, GOG and Amazon games"
    "Gaming|Lutris|net.lutris.Lutris|Launcher for Wine games and emulators"
    "Gaming|Bottles|com.usebottles.bottles|Windows apps and games in isolated Wine bottles"
    "Gaming|PortProton|ru.linux_gaming.PortProton|Portable Proton/Wine launcher for Windows games"
    "Gaming|Prism Launcher|org.prismlauncher.PrismLauncher|Minecraft launcher, instances and modpacks"
    "Gaming|Sober|org.vinegarhq.Sober|Roblox on Linux"
    "Gaming|QRookie|io.github.glaumar.QRookie|Quest/VR game sideloading"
    "Gaming|Cartridges|page.kramo.Cartridges|One library for all your game launchers"
    "Gaming|GOverlay|io.github.benjamimgois.goverlay|GUI for the MangoHud FPS overlay"
    "Gaming|Moonlight|com.moonlight_stream.Moonlight|Stream games from a PC"
    "Gaming|Sunshine|dev.lizardbyte.app.Sunshine|Game streaming host for Moonlight"
    "Gaming|Chiaki|re.chiaki.chiaki4deck|PlayStation 4/5 Remote Play"
    # Emulators
    "Emulators|RetroArch|org.libretro.RetroArch|Multi-system emulator frontend"
    "Emulators|Dolphin Emulator|org.DolphinEmu.dolphin-emu|GameCube and Wii"
    "Emulators|PCSX2|net.pcsx2.PCSX2|PlayStation 2"
    "Emulators|DuckStation|org.duckstation.DuckStation|PlayStation 1"
    "Emulators|RPCS3|net.rpcs3.RPCS3|PlayStation 3"
    "Emulators|Flycast|org.flycast.Flycast|Dreamcast and Naomi"
    "Emulators|ScummVM|org.scummvm.ScummVM|Classic point-and-click adventures"
    "Emulators|OpenRA|net.openra.OpenRA|Red Alert, Tiberian Dawn and Dune 2000 remakes"
    # Gaming Devices & Accessibility
    "Devices & Accessibility|Solaar|io.github.pwr_solaar.solaar|Logitech wireless devices - battery, DPI, pairing"
    "Devices & Accessibility|Piper|org.freedesktop.Piper|Configure gaming mice (Logitech, Razer and others)"
    "Devices & Accessibility|OpenRGB|org.openrgb.OpenRGB|RGB lighting control for many brands"
    "Devices & Accessibility|Speech Note|net.mkiol.SpeechNote|Offline speech-to-text, text-to-speech, translation"
    # Torrents
    "Torrents|qBittorrent|org.qbittorrent.qBittorrent|Full-featured torrent client"
    "Torrents|Transmission|com.transmissionbt.Transmission|Lightweight torrent client"
    "Torrents|Fragments|de.haeckerfelix.Fragments|Simple GNOME torrent client"
    # Education & Science
    "Education & Science|LabPlot|org.kde.labplot2|Data analysis and plotting"
    "Education & Science|Cantor|org.kde.cantor|Maxima, Octave, R and Python frontend"
    "Education & Science|KAlgebra|org.kde.kalgebra|Algebra and graphing"
    "Education & Science|Kalzium|org.kde.kalzium|Periodic table and chemistry"
    "Education & Science|Step|org.kde.step|Physics simulator"
    "Education & Science|KStars|org.kde.kstars|Desktop planetarium"
    "Education & Science|Stellarium|org.stellarium.Stellarium|Realistic night sky"
    "Education & Science|Marble|org.kde.marble|Virtual globe and atlas"
    "Education & Science|KGeography|org.kde.kgeography|Geography learning"
    "Education & Science|KTurtle|org.kde.kturtle|Learn programming with LOGO"
    "Education & Science|Anki|net.ankiweb.Anki|Flashcards with spaced repetition"
    # Development
    "Development|VSCodium|com.vscodium.codium|VS Code without telemetry (Flatpak, sandboxed)"
    "Development|VSCodium Native (Full System Access)|rpm:vscodium|Native install, not sandboxed - reboot required"
    "Development|VS Code (Microsoft)|com.visualstudio.code|Official VS Code"
    "Development|IntelliJ IDEA Community|com.jetbrains.IntelliJ-IDEA-Community|Java/JVM IDE"
    "Development|PyCharm Community|com.jetbrains.PyCharm-Community|Python IDE"
    "Development|GitHub Desktop|io.github.shiftey.Desktop|Git GUI"
    "Development|Godot Engine|org.godotengine.Godot|Game engine"
    "Development|Pods|com.github.marhkb.Pods|Podman container manager"
    "Development|GitHub CLI|rpm:gh|gh command - reboot required"
    "Development|Neovim|rpm:neovim|Terminal editor - reboot required"
    "Development|C/C++ toolchain|rpm:gcc make cmake|GCC, Make, CMake - reboot required"
    # System & Utilities
    "System & Utilities|Mission Center|io.missioncenter.MissionCenter|Windows-style Task Manager - processes, performance, startup"
    "System & Utilities|Warehouse|io.github.flattool.Warehouse|Manage and fully uninstall Flatpaks, including their data"
    "System & Utilities|Flatseal|com.github.tchx84.Flatseal|Flatpak permissions"
    "System & Utilities|BleachBit|org.bleachbit.BleachBit|Cache and junk cleanup"
    "System & Utilities|Filelight|org.kde.filelight|See what is using disk space"
    "System & Utilities|File Roller|org.gnome.FileRoller|Alternative archive manager"
    "System & Utilities|Impression|io.gitlab.adhami3310.Impression|Write OS images to USB drives"
    "System & Utilities|Deja Dup|org.gnome.DejaDup|Scheduled encrypted backups"
    "System & Utilities|Warp|app.drey.Warp|Send files between devices"
    "System & Utilities|RustDesk|com.rustdesk.RustDesk|Remote desktop"
    "System & Utilities|Remmina|org.remmina.Remmina|RDP, VNC and SSH client"
    "System & Utilities|GNOME Boxes|org.gnome.Boxes|Run virtual machines"
    "System & Utilities|btop|rpm:btop|Terminal resource monitor - reboot required"
    # Fun & Reading
    "Fun & Reading|Foliate|com.github.johnfactotum.Foliate|E-book reader (EPUB, MOBI)"
    "Fun & Reading|Calibre|com.calibre_ebook.calibre|E-book library manager"
    "Fun & Reading|Tuba|dev.geopjr.Tuba|Mastodon client"
    "Fun & Reading|Cavalier|org.nickvision.cavalier|Audio visualiser"
)

# ── Build zenity argument list (sorted by category, then name) ─────────────────
declare -A SEEN_ID
ZENITY_ARGS=()
while IFS='|' read -r cat name id desc; do
    [[ -z "${id}" || -n "${SEEN_ID[${id}]:-}" ]] && continue
    SEEN_ID["${id}"]=1
    ZENITY_ARGS+=("FALSE" "${cat}" "${name}" "${id}" "${desc}")
done < <(printf '%s\n' "${APP_CATALOGUE[@]}" | sort -t'|' -k1,1 -k2,2f)

# ── Show dialog ───────────────────────────────────────────────────────────────
SELECTED=$(
    zenity \
        --list \
        --title="Raptor OS — Optional Apps" \
        --text="<b>Pick the apps you want.</b> Nothing is selected by default.\nClick the <b>Category</b> header to group by type. Everything here can be installed later, too." \
        --checklist \
        --column="Install" \
        --column="Category" \
        --column="Application" \
        --column="ID" \
        --column="Description" \
        --hide-column=4 \
        --print-column=4 \
        --separator="|" \
        "${ZENITY_ARGS[@]}" \
        --width=900 --height=650 \
        --ok-label="Install Selected" \
        --cancel-label="Skip — Install Nothing" \
        2>/dev/null
) || true

# ── Always write stamp so we never loop ───────────────────────────────────────
mkdir -p "$(dirname "${STAMP_FILE}")"
touch "${STAMP_FILE}"

if [[ -z "${SELECTED:-}" ]]; then
    log "App selection skipped or nothing selected."
    exit 0
fi
log "User selected: ${SELECTED}"

declare -A ID_TO_NAME
for entry in "${APP_CATALOGUE[@]}"; do
    IFS='|' read -r _cat name id _desc <<< "${entry}"
    ID_TO_NAME["${id}"]="${name}"
done

INSTALL_LOG=/tmp/raptor-app-install.log
FAILED=()
NEEDS_REBOOT=0
IFS='|' read -ra TO_INSTALL <<< "${SELECTED}"

for sel_id in "${TO_INSTALL[@]}"; do
    sel_id="${sel_id//\"/}"
    [[ -z "${sel_id}" ]] && continue
    app_name="${ID_TO_NAME[${sel_id}]:-${sel_id}}"
    log "Installing ${app_name} (${sel_id})…"

    if [[ "${sel_id}" == rpm:* ]]; then
        RPM_PKG="${sel_id#rpm:}"
        case "${RPM_PKG}" in
            vscodium|vscodium-insiders)
                RPM_NAME="codium"; [ "${RPM_PKG}" = "vscodium-insiders" ] && RPM_NAME="codium-insiders"

                if ! command -v dnf &>/dev/null; then
                    err "dnf not available — cannot register the VSCodium repository."
                    FAILED+=("${app_name}")
                    continue
                fi

                # Writes /etc/yum.repos.d/VSCodium.repo. rpm-ostree does read
                # repo files from that directory, so this is the supported way
                # to reach a third-party repo.
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
                    err "Failed to register the VSCodium repository."
                    FAILED+=("${app_name}")
                    continue
                fi

                # rpm-ostree keeps its own cached copy of the repo metadata and
                # will not see a repo added a moment ago without this refresh.
                # Skipping it is why this step used to fail with "no package
                # matched" while /etc/yum.repos.d/VSCodium.repo was present.
                if ! sudo rpm-ostree cleanup -m >> /tmp/raptor-app-install.log 2>&1; then
                    err "rpm-ostree metadata refresh failed — see /tmp/raptor-app-install.log"
                    FAILED+=("${app_name}")
                    continue
                fi

                if sudo rpm-ostree install --idempotent --allow-inactive "${RPM_NAME}" \
                        >> /tmp/raptor-app-install.log 2>&1; then
                    NEEDS_REBOOT=1
                    log "OK (rpm-ostree, native): ${app_name}"
                else
                    err "${app_name}: could not be layered. See /tmp/raptor-app-install.log, or install the Flatpak version instead."
                    FAILED+=("${app_name}")
                fi
                ;;
            *)
                # shellcheck disable=SC2086
                if sudo rpm-ostree install --idempotent --allow-inactive ${RPM_PKG} \
                        >> "${INSTALL_LOG}" 2>&1; then
                    NEEDS_REBOOT=1
                    log "OK (rpm-ostree): ${app_name}"
                else
                    err "${app_name}: rpm-ostree failed, see ${INSTALL_LOG}"
                    FAILED+=("${app_name} (system package)")
                fi
                ;;
        esac
    else
        # Verify the ID exists on Flathub first — a bad ID is reported by name.
        if ! flatpak remote-info --user flathub "${sel_id}" >> "${INSTALL_LOG}" 2>&1; then
            err "NOT ON FLATHUB: ${app_name} (${sel_id})"
            FAILED+=("${app_name} (not found on Flathub)")
            continue
        fi
        if flatpak install --user -y --noninteractive flathub "${sel_id}" \
                >> "${INSTALL_LOG}" 2>&1; then
            log "OK: ${app_name}"
        else
            err "FAILED: ${app_name} (${sel_id})"
            FAILED+=("${app_name}")
        fi
    fi
done

# ── Result dialog ─────────────────────────────────────────────────────────────
REBOOT_NOTE=""
[[ "${NEEDS_REBOOT}" -eq 1 ]] && REBOOT_NOTE="\n\nSystem packages were staged and appear after a reboot."

if [[ ${#FAILED[@]} -eq 0 ]]; then
    zenity --info --title="Raptor OS — Setup Complete" \
        --text="All selected applications were installed.${REBOOT_NOTE}" \
        --width=380 2>/dev/null || true
else
    FAIL_LIST=$(printf '  • %s\n' "${FAILED[@]}")
    zenity --warning --title="Some Apps Failed to Install" \
        --text="These could not be installed:\n\n${FAIL_LIST}${REBOOT_NOTE}\n\nDetails: ${INSTALL_LOG}" \
        --width=420 2>/dev/null || true
fi
log "App selection complete."
