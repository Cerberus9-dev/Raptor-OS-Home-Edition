#!/bin/bash
# raptor-browser-choice.sh  v4.0
# First-boot browser selection dialog for Raptor OS.
#
# Features:
#  - No browser ships in the image — the default stays minimal. Five popular
#    browsers (Firefox, Brave, Chromium, Chrome, Edge) are all offered here
#    as on-demand Flathub downloads.
#  - Network connectivity check before attempting the download
#  - Zenity progress dialog during download (~100-150 MB)
#  - Retry prompt on failure rather than silently falling back
#  - Idempotent — stamp prevents re-running after a successful choice
#  - "Skip — No Browser" cancel = valid choice, stamp written, dialog never
#    repeats (nothing is installed and no default is forced)
#  - If the chosen browser is already installed (e.g. user picked Chrome in
#    the app picker), it is simply set as the default — no re-download.
#
# Runs as part of raptor-firstboot.service (user service) after Plasma is up.
# Stamp: ~/.local/share/raptor/browser-choice-done

set -euo pipefail

STAMP_FILE="${HOME}/.local/share/raptor/browser-choice-done"
LOG_TAG="raptor-browser-choice"
INSTALL_LOG="/tmp/raptor-browser-install.log"

log()  { logger -t "${LOG_TAG}" -- "$*";              }
err()  { logger -t "${LOG_TAG}" -p user.err -- "$*";  }
info() { logger -t "${LOG_TAG}" -p user.info -- "$*"; }

# ── Guard: already chosen ─────────────────────────────────────────────────────
if [[ -f "${STAMP_FILE}" ]]; then
    log "Browser choice already made — skipping."
    exit 0
fi

# ── Prerequisite: zenity must be available ────────────────────────────────────
if ! command -v zenity &>/dev/null; then
    err "zenity not found — cannot show browser dialog. Writing stamp to avoid loop."
    mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"
    exit 0
fi

# ── Helper: write stamp and exit cleanly ──────────────────────────────────────
finish() {
    mkdir -p "$(dirname "${STAMP_FILE}")"
    touch "${STAMP_FILE}"
    log "Browser choice complete. Stamp written."
}

# ── Helper: check network before spending time on a doomed download ───────────
check_network() {
    if ! curl --silent --max-time 5 --head https://flathub.org >/dev/null 2>&1; then
        zenity --error \
            --title="No Internet Connection" \
            --text="Raptor OS needs an internet connection to download a browser.\n\nNo browser was installed. You can install one later from the Raptor welcome app, or stop any browser from Discover / the terminal." \
            --width=420 2>/dev/null || true
        return 1
    fi
    return 0
}

# ── Helper: install a Flatpak with a progress dialog ─────────────────────────
install_with_progress() {
    local flatpak_id="$1"
    local display_name="$2"
    local size_hint="$3"   # e.g. "~120 MB"

    info "Starting Flatpak install: ${flatpak_id}"

    # Run the install in the background, pipe progress updates to zenity
    (
        flatpak install -y --noninteractive flathub "${flatpak_id}" \
            >> "${INSTALL_LOG}" 2>&1
        echo "100"
    ) | zenity --progress \
            --title="Installing ${display_name}" \
            --text="Downloading ${display_name} from Flathub (${size_hint})…\n\nThis may take a few minutes depending on your internet speed." \
            --pulsate \
            --auto-close \
            --no-cancel \
            --width=420 2>/dev/null || true

    # Verify install succeeded regardless of the progress dialog result
    if flatpak info "${flatpak_id}" &>/dev/null; then
        info "${flatpak_id} installed successfully"
        return 0
    else
        err "${flatpak_id} install failed — see ${INSTALL_LOG}"
        return 1
    fi
}

# ── Helper: set the XDG default browser ───────────────────────────────────────
set_default_browser() {
    local desktop_id="$1"
    xdg-settings set default-web-browser "${desktop_id}" 2>/dev/null \
        && info "Default browser set to ${desktop_id}" \
        || err "Could not set default browser to ${desktop_id} via xdg-settings"

    # Also set via kwriteconfig6 for KDE's own browser launch button in Plasma
    if command -v kwriteconfig6 &>/dev/null; then
        kwriteconfig6 \
            --file kdeglobals \
            --group "General" \
            --key "BrowserApplication" \
            "${desktop_id}" 2>/dev/null || true
    fi
}

# ── Browser catalogue ─────────────────────────────────────────────────────────
# Format: "DISPLAY_NAME|FLATPAK_ID|DESKTOP_ID|SIZE|NOTE"
# All five are downloads; none ships in the image.
BROWSERS=(
    "Firefox|org.mozilla.firefox|firefox.desktop|~120 MB|Privacy-first · tab isolation · open source"
    "Brave|com.brave.Browser|com.brave.Browser.desktop|~120 MB|Chromium · built-in ad blocker"
    "Chromium|org.chromium.Chromium|org.chromium.Chromium.desktop|~100 MB|Plain Chromium · the open-source core"
    "Chrome|com.google.Chrome|com.google.Chrome.desktop|~150 MB|Google Chrome · familiar · most compatible"
    "Edge|com.microsoft.Edge|com.microsoft.Edge.desktop|~150 MB|Microsoft Edge · Chromium based"
)

# ── Build zenity argument list ────────────────────────────────────────────────
# Firefox is pre-selected as the sane default; every entry is installed on
# confirm if it isn't already present.
ZENITY_ARGS=()
for entry in "${BROWSERS[@]}"; do
    IFS='|' read -r name _id _desktop size note <<< "${entry}"
    if [[ "${name}" == "Firefox" ]]; then
        ZENITY_ARGS+=(TRUE  "${name}" "${note} (${size})")
    else
        ZENITY_ARGS+=(FALSE "${name}" "${note} (${size})")
    fi
done

# ── Dialog ────────────────────────────────────────────────────────────────────
CHOICE=$(
    zenity \
        --list \
        --title="Welcome to Raptor OS" \
        --text="<b>Choose your web browser</b>\n\nNo browser is pre-installed — the image stays minimal.\nFirefox is pre-selected; any choice is a one-time download from Flathub.\n" \
        --radiolist \
        --column="" \
        --column="Browser" \
        --column="Notes" \
        "${ZENITY_ARGS[@]}" \
        --width=560 --height=330 \
        --ok-label="Install & Use" \
        --cancel-label="Skip — No Browser" \
        2>/dev/null
) || true

# ── Skip ──────────────────────────────────────────────────────────────────────
if [[ -z "${CHOICE:-}" ]]; then
    log "User skipped browser choice — no browser installed, no default forced."
    finish
    exit 0
fi

# ── Resolve chosen browser ────────────────────────────────────────────────────
SELECTED=""
for entry in "${BROWSERS[@]}"; do
    IFS='|' read -r name fid desktop size note <<< "${entry}"
    if [[ "${name}" == "${CHOICE}" ]]; then
        SELECTED="${name}|${fid}|${desktop}|${size}|${note}"
        break
    fi
done

if [[ -z "${SELECTED}" ]]; then
    err "Unexpected choice value: '${CHOICE}' — aborting browser install."
    finish
    exit 0
fi

IFS='|' read -r NAME FID DESKTOP SIZE NOTE <<< "${SELECTED}"
log "User selected browser: ${NAME}"

# ── Already installed? ────────────────────────────────────────────────────────
if flatpak info "${FID}" &>/dev/null; then
    info "${FID} already installed — setting as default only."
    set_default_browser "${DESKTOP}"
    finish
    exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
if ! check_network; then
    finish
    exit 0
fi

INSTALL_OK=0
if install_with_progress "${FID}" "${NAME}" "${SIZE}"; then
    set_default_browser "${DESKTOP}"
    log "${NAME} installed and set as default."
    INSTALL_OK=1
else
    # Offer retry
    if zenity --question \
            --title="Installation Failed" \
            --text="${NAME} could not be installed.\n\nWould you like to try again?\n\nIf you choose No, nothing is installed and no default is set." \
            --ok-label="Try Again" \
            --cancel-label="Skip — No Browser" \
            --width=400 2>/dev/null; then
        # Second attempt — no progress dialog, just wait
        if flatpak install -y --noninteractive flathub "${FID}" \
                >> "${INSTALL_LOG}" 2>&1 \
                && flatpak info "${FID}" &>/dev/null; then
            set_default_browser "${DESKTOP}"
            log "${NAME} installed on retry."
            INSTALL_OK=1
        else
            err "${NAME} install failed on retry. Nothing installed."
        fi
    else
        err "User declined retry. Nothing installed."
    fi
fi

if [[ "${INSTALL_OK}" -eq 1 ]]; then
    zenity --info \
        --title="${NAME} is Ready" \
        --text="✓ ${NAME} has been installed and set as your default browser." \
        --width=300 2>/dev/null || true
fi

finish