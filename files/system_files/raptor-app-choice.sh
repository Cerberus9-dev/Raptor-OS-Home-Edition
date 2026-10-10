#!/usr/bin/env bash
# raptor-app-choice.sh
# First-boot optional-app selection dialog.
# v2.1: corrected Flatpak IDs (e.g. Sober org.vinegarhq.Sober), proper rpm/native handling, validation
set -euo pipefail

STAMP_FILE="${HOME}/.local/share/raptor/app-choice-done"
LOG_TAG="raptor-app-choice"
NEEDS_REBOOT=0

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

declare -A APP_LIST
# Category|DisplayName|Type(flatpak/rpm)|ID/Package|Description
APP_LIST=(
    ["System:BleachBit"]="System|BleachBit|rpm|bleachbit|System cleaner"
    ["Dev:Neovim"]="Development|Neovim|rpm|neovim|Terminal editor"
)
