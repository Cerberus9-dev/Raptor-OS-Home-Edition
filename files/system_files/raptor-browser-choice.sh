#!/bin/bash
# raptor-browser-choice.sh  v4.0
# First-boot browser selection dialog for Raptor OS.
#
# Features:
#  - No browser ships in the image — the default stays minimal. Five popular
#    browsers (Firefox, Brave, Chromium, Chrome, Edge) are all offered here
#    as on-demand Flathub downloads.
#  - Network connectivity check before even showing the dialog, and an offline
#    first boot deliberately leaves the stamp unwritten so the choice is offered
#    again next login (first boot is often before WiFi is joined)
#  - Zenity progress dialog during download (~100-150 MB)
#  - Retry prompt on failure rather than silently falling back
#  - Idempotent — stamp prevents re-running after a successful choice
#  - "Skip — No Browser" cancel = valid choice, stamp written, dialog never
#    repeats (nothing is installed and no default is forced)
#  - If the chosen browser is already installed (e.g. user picked Chrome in
#    the app picker), it is simply set as the default — no re-download.
#  - The desktop id is read back from the installed Flatpak rather than
#    hardcoded, so a Flathub rename cannot leave a browser installed but
#    never made the default.
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
            --text="Raptor OS needs an internet connection to download a browser.\n\nNo browser was installed, and this will be offered again next time you log in — nothing was recorded, so nothing is missed.\n\nYou can also install a browser any time from Discover, Flatpak, or the Raptor welcome app." \
            --width=420 2>/dev/null || true
        return 1
    fi
    return 0
}

# ── Helper: find the desktop id the Flatpak actually exported ─────────────────
# Hardcoding these is how Firefox ended up installed but never made the default:
# Flathub renamed firefox.desktop to org.mozilla.firefox.desktop, so the
# hardcoded id no longer resolved, xdg-settings quietly failed, and the user was
# still shown a "set as your default browser" success message. Ask the
# installed Flatpak what it really exports instead.
resolve_desktop_id() {
    local fid="$1" preferred="$2" loc dir cand
    loc=$(flatpak info --show-location "${fid}" 2>/dev/null) || return 1
    [ -n "${loc}" ] || return 1
    dir="${loc}/files/share/applications"
    [ -d "${dir}" ] || return 1
    # A still-valid preferred id wins, so the common case is unchanged.
    if [ -f "${dir}/${preferred}" ]; then
        printf '%s\n' "${preferred}"
        return 0
    fi
    cand=$(find "${dir}" -maxdepth 1 -name '*.desktop' -print -quit 2>/dev/null)
    [ -n "${cand}" ] || return 1
    basename "${cand}"
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
# Returns 0 only if a default was actually applied. Callers use this to avoid
# telling the user their browser is the default when it is not.
set_default_browser() {
    local desktop_id="$1" xdg_ok=0 kde_ok=0

    if [ -z "${desktop_id}" ]; then
        err "No desktop id resolved — cannot set a default browser."
        return 1
    fi

    if xdg-settings set default-web-browser "${desktop_id}" 2>/dev/null; then
        info "Default browser set to ${desktop_id}"
        xdg_ok=1
    else
        err "Could not set default browser to ${desktop_id} via xdg-settings"
    fi

    # Also set via kwriteconfig6 for KDE's own browser launch button in Plasma
    if command -v kwriteconfig6 &>/dev/null; then
        if kwriteconfig6 \
                --file kdeglobals \
                --group "General" \
                --key "BrowserApplication" \
                "${desktop_id}" 2>/dev/null; then
            kde_ok=1
        else
            err "Could not set kdeglobals BrowserApplication"
        fi
    else
        # No kwriteconfig6 (non-KDE session) — not a failure on its own.
        kde_ok=1
    fi

    # KDE is the session this image ships, so both halves must land.
    if [ "${xdg_ok}" -eq 1 ] && [ "${kde_ok}" -eq 1 ]; then
        return 0
    fi
    return 1
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

# ── Network check first, before asking the user to choose ─────────────────────
# Asking first and checking afterwards means an offline user picks a browser,
# waits through a dialog, and is then told it cannot be downloaded. Worse, the
# old code wrote the stamp even on this failure path, so because
# raptor-firstboot.service re-runs until all three stamps exist, that user was
# never asked again and silently ended up with no browser at all — and first
# boot is exactly when WiFi is often not joined yet. Leave the stamp unwritten
# so the choice is offered again on the next login.
if ! check_network; then
    log "No network at first boot — browser choice deferred to next login."
    exit 0
fi

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
    real_desktop=$(resolve_desktop_id "${FID}" "${DESKTOP}" || echo "")
    if set_default_browser "${real_desktop}"; then
        finish
    else
        err "${NAME} is installed but the default browser could not be set."
        zenity --warning \
            --title="Could Not Set Default" \
            --text="${NAME} is installed, but Raptor OS could not make it your default browser.\n\nSet it in System Settings → Default Applications, or with:\n\nxdg-settings set default-web-browser ${real_desktop:-<desktop-id>}" \
            --width=460 2>/dev/null || true
        finish
    fi
    exit 0
fi

# ── Install ───────────────────────────────────────────────────────────────────
INSTALL_OK=0
DEFAULT_OK=0
if install_with_progress "${FID}" "${NAME}" "${SIZE}"; then
    real_desktop=$(resolve_desktop_id "${FID}" "${DESKTOP}" || echo "")
    if set_default_browser "${real_desktop}"; then
        log "${NAME} installed and set as default."
        DEFAULT_OK=1
    else
        err "${NAME} installed but the default browser could not be set."
    fi
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
            real_desktop=$(resolve_desktop_id "${FID}" "${DESKTOP}" || echo "")
            if set_default_browser "${real_desktop}"; then
                log "${NAME} installed on retry."
                DEFAULT_OK=1
            else
                err "${NAME} installed on retry but the default could not be set."
            fi
            INSTALL_OK=1
        else
            err "${NAME} install failed on retry. Nothing installed."
        fi
    else
        err "User declined retry. Nothing installed."
    fi
fi

# Only claim the default was set when it actually was. Telling the user their
# new browser is the default when xdg-settings failed is worse than saying
# nothing, because they will not look again.
if [[ "${INSTALL_OK}" -eq 1 ]]; then
    if [[ "${DEFAULT_OK}" -eq 1 ]]; then
        zenity --info \
            --title="${NAME} is Ready" \
            --text="✓ ${NAME} has been installed and set as your default browser." \
            --width=300 2>/dev/null || true
    else
        zenity --warning \
            --title="${NAME} is Ready" \
            --text="${NAME} has been installed, but Raptor OS could not make it your default browser.\n\nSet it in System Settings → Default Applications." \
            --width=440 2>/dev/null || true
    fi
fi

finish