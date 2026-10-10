#!/usr/bin/env bash
# raptor-app-choice.sh
# First-boot optional-app selection dialog
set -euo pipefail

STAMP_FILE="${HOME}/.local/share/raptor/app-choice-done"
LOG_TAG="raptor-app-choice"

log() { logger -t "${LOG_TAG}" -- "$*"; }
err() { logger -t "${LOG_TAG}" -p user.err -- "$*"; }

if [[ -f "${STAMP_FILE}" ]]; then
    log "App selection already done — skipping."
    exit 0
fi

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

flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true

OPTIONS=()
OPTIONS+=("TRUE|01|Browser - Brave|flathub|com.brave.Browser|A fast, privacy-focused web browser.")
OPTIONS+=("TRUE|02|Browser - Firefox|flathub|org.mozilla.firefox|Mozilla's open-source web browser.")
OPTIONS+=("TRUE|03|Browser - LibreWolf|flathub|io.gitlab.librewolf-community|Privacy-focused Firefox-based browser.")
OPTIONS+=("TRUE|04|Browser - Ungoogled Chromium|flathub|com.github.Eloston.UngoogledChromium|Chromium without Google services.")
OPTIONS+=("TRUE|05|Media - VLC|flathub|org.videolan.VLC|Open-source media player.")
OPTIONS+=("TRUE|06|Media - Parabolic|flathub|org.nickvision.tubeconverter|Download videos from websites.")
OPTIONS+=("TRUE|07|Utility - Mission Center|flathub|io.missioncenter.MissionCenter|System resource monitor and task manager.")
OPTIONS+=("TRUE|08|Games - Heroic Games Launcher|flathub|com.heroicgameslauncher.hgl|Launcher for Epic, GOG, Amazon games.")
OPTIONS+=("TRUE|09|Games - Lutris|flathub|net.lutris.Lutris|Open-source game manager.")
OPTIONS+=("TRUE|10|Games - Bottles|flathub|com.usebottles.bottles|Run Windows apps in managed prefixes.")
OPTIONS+=("TRUE|11|Comms - Discord|flathub|com.discordapp.Discord|Chat and voice.")
OPTIONS+=("TRUE|12|Comms - Element|flathub|im.riot.Riot|Matrix chat client.")
OPTIONS+=("TRUE|13|Comms - Signal|flathub|org.signal.Signal|Private messaging.")
OPTIONS+=("TRUE|14|System - Stacer|flathub|io.github.ozmarties.Stacer|System optimizer and monitor.")
OPTIONS+=("TRUE|15|System - Warehouse|flathub|io.github.flattool.Warehouse|Flatpak management tool.")
OPTIONS+=("FALSE|16|Terminal - btop|rpm|btop|Resource monitor (requires reboot after install).")
OPTIONS+=("FALSE|17|Utility - Neovim|rpm|neovim|Terminal text editor.")

CHOICES=$(printf '%s\n' "${OPTIONS[@]}" | zenity \
    --list \
    --checklist \
    --title="Raptor OS - Optional Apps" \
    --text="Select applications to install:" \
    --column="Select" \
    --column="ID" \
    --column="Name" \
    --column="Type" \
    --column="Package/ID" \
    --column="Description" \
    --separator="|" \
    --width=700 \
    --height=550 2>/dev/null || true)

if [[ -z "${CHOICES}" ]]; then
    mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"
    log "User skipped selection. Stamp written."
    exit 0
fi

NEEDS_REBOOT=0
FAILED=()

IFS='|' read -ra ITEMS <<< "${CHOICES}"
for item in "${ITEMS[@]}"; do
    [[ -z "${item}" ]] && continue
    for opt in "${OPTIONS[@]}"; do
        IFS='|' read -r sel id name type pkg desc <<< "${opt}"
        if [[ "${id}" == "${item}" ]]; then
            log "Installing: ${name}"
            if [[ "${type}" == "rpm" ]]; then
                if rpm-ostree install -y "${pkg}" >/tmp/raptor-install-${id}.log 2>&1; then
                    log "OK (rpm-ostree staged): ${pkg}"
                    NEEDS_REBOOT=1
                else
                    err "FAILED rpm: ${pkg}"
                    FAILED+=("${name}")
                fi
            elif [[ "${type}" == "flathub" ]]; then
                if flatpak install -y --noninteractive flathub "${pkg}" >/tmp/raptor-install-${id}.log 2>&1; then
                    log "OK: ${name}"
                else
                    err "FAILED flatpak: ${pkg}"
                    FAILED+=("${name}")
                fi
            fi
            break
        fi
    done
done

mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"

if [[ ${#FAILED[@]} -eq 0 ]]; then
    if [[ "${NEEDS_REBOOT}" -eq 1 ]]; then
        zenity --info --title="Raptor OS - Setup Complete" --text="All selected apps installed.\n\nSome system packages were staged and will be available after reboot." --width=380 2>/dev/null || true
    else
        zenity --info --title="Raptor OS - Setup Complete" --text="All selected apps installed successfully." --width=340 2>/dev/null || true
    fi
else
    FAIL_LIST=$(printf '  • %s\n' "${FAILED[@]}")
    REBOOT_NOTE=""
    [[ "${NEEDS_REBOOT}" -eq 1 ]] && REBOOT_NOTE="\n\nSome system packages were staged and will appear after reboot."
    zenity --warning --title="Some Apps Failed to Install" --text="The following could not be installed:\n\n${FAIL_LIST}${REBOOT_NOTE}" --width=400 2>/dev/null || true
fi

log "App selection complete."
exit 0
