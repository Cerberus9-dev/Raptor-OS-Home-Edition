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
    err "zenity not found"
    mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"
    exit 0
fi

if ! command -v flatpak &>/dev/null; then
    err "flatpak not found"
    mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"
    exit 0
fi

flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true

OPTIONS=(
    "TRUE|01|Browser - Brave|flathub|com.brave.Browser|Privacy-focused browser"
    "TRUE|02|Browser - Firefox|flathub|org.mozilla.firefox|Open-source browser"
    "TRUE|03|Media - VLC|flathub|org.videolan.VLC|Media player"
    "TRUE|04|Utility - Mission Center|flathub|io.missioncenter.MissionCenter|System monitor"
    "TRUE|05|Games - Heroic Games Launcher|flathub|com.heroicgameslauncher.hgl|Game launcher"
    "TRUE|06|Games - Lutris|flathub|net.lutris.Lutris|Game manager"
    "TRUE|07|Comms - Discord|flathub|com.discordapp.Discord|Chat & voice"
    "TRUE|08|System - Stacer|flathub|io.github.ozmarties.Stacer|System utility"
    "FALSE|09|Terminal - btop|rpm|btop|System monitor (reboot needed)"
)

CHOICES=$(printf '%s\n' "${OPTIONS[@]}" | zenity \
    --list --checklist --title="Raptor OS - Optional Apps" \
    --text="Select applications to install:" \
    --column="Select" --column="ID" --column="Name" --column="Type" --column="Package/ID" --column="Description" \
    --separator="|" --width=600 --height=400 2>/dev/null || true)

if [[ -z "${CHOICES}" ]]; then
    mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"
    exit 0
fi

NEEDS_REBOOT=0
FAILED=()

IFS='|' read -ra ITEMS <<< "${CHOICES}"
for item in "${ITEMS[@]}"; do
    [[ -z "$item" ]] && continue
    for opt in "${OPTIONS[@]}"; do
        IFS='|' read -r sel id name type pkg desc <<< "$opt"
        if [[ "$id" == "$item" ]]; then
            if [[ "$type" == "rpm" ]]; then
                if rpm-ostree install -y "$pkg" >/tmp/raptor-install-$id.log 2>&1; then
                    NEEDS_REBOOT=1
                else
                    FAILED+=("$name")
                fi
            elif [[ "$type" == "flathub" ]]; then
                if flatpak install -y --noninteractive flathub "$pkg" >/tmp/raptor-install-$id.log 2>&1; then
                    :
                else
                    FAILED+=("$name")
                fi
            fi
            break
        fi
    done
done

mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"

if [[ ${#FAILED[@]} -eq 0 ]]; then
    if [[ $NEEDS_REBOOT -eq 1 ]]; then
        zenity --info --title="Raptor OS - Setup Complete" --text="All selected apps installed.\n\nSome system packages were staged and will be available after reboot." --width=380 2>/dev/null || true
    else
        zenity --info --title="Raptor OS - Setup Complete" --text="All selected apps installed successfully." --width=340 2>/dev/null || true
    fi
else
    FAIL_LIST=$(printf '  • %s\n' "${FAILED[@]}")
    zenity --warning --title="Some Apps Failed to Install" --text="The following could not be installed:\n\n${FAIL_LIST}" --width=400 2>/dev/null || true
fi

exit 0
