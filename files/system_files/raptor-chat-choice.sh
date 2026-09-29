#!/bin/bash
# raptor-chat-choice.sh  v1.0
# First-boot Discord/Vesktop selection dialog for Raptor OS.
#
# Vesktop was previously a mandatory default install. Moved to a firstboot
# choice alongside official Discord for a truly bare-basics default image —
# and because the two have a genuine, real tradeoff worth disclosing rather
# than silently picking one on the user's behalf:
#   - Discord (official): better Rich Presence support — some game/app
#     integrations specifically target the official client
#   - Vesktop: built around Vencord, so plugins/themes/customization work
#     out of the box without a separate install step
#
# Neither is pre-installed, so unlike the browser dialog there's no "keep
# what's already there" free option — both need a Flathub download. "Skip"
# is a fully valid choice; not everyone wants a Discord client at all.
#
# Runs as part of raptor-firstboot.service (user service) after Plasma is up.
# Stamp: ~/.local/share/raptor/chat-choice-done

set -euo pipefail

STAMP_FILE="${HOME}/.local/share/raptor/chat-choice-done"
LOG_TAG="raptor-chat-choice"
INSTALL_LOG="/tmp/raptor-chat-install.log"

log()  { logger -t "${LOG_TAG}" -- "$*";              }
err()  { logger -t "${LOG_TAG}" -p user.err -- "$*";  }
info() { logger -t "${LOG_TAG}" -p user.info -- "$*"; }

# ── Guard: already chosen ─────────────────────────────────────────────────────
if [[ -f "${STAMP_FILE}" ]]; then
    log "Chat client choice already made — skipping."
    exit 0
fi

# ── Prerequisite: zenity must be available ────────────────────────────────────
if ! command -v zenity &>/dev/null; then
    err "zenity not found — cannot show chat client dialog. Writing stamp to avoid loop."
    mkdir -p "$(dirname "${STAMP_FILE}")" && touch "${STAMP_FILE}"
    exit 0
fi

finish() {
    mkdir -p "$(dirname "${STAMP_FILE}")"
    touch "${STAMP_FILE}"
    log "Chat client choice complete. Stamp written."
}

check_network() {
    if ! curl --silent --max-time 5 --head https://flathub.org >/dev/null 2>&1; then
        zenity --error \
            --title="No Internet Connection" \
            --text="Raptor OS needs an internet connection to download a chat client.\n\nNo chat client was installed, and this will be offered again next time you log in — nothing was recorded, so nothing is missed.\n\nYou can also install one any time from Discover or Flatpak." \
            --width=400 2>/dev/null || true
        return 1
    fi
    return 0
}

install_with_progress() {
    local flatpak_id="$1"
    local display_name="$2"
    local size_hint="$3"

    info "Starting Flatpak install: ${flatpak_id}"

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

    if flatpak info "${flatpak_id}" &>/dev/null; then
        info "${flatpak_id} installed successfully"
        return 0
    else
        err "${flatpak_id} install failed — see ${INSTALL_LOG}"
        return 1
    fi
}

install_with_retry() {
    local flatpak_id="$1"
    local display_name="$2"
    local size_hint="$3"

    if install_with_progress "$flatpak_id" "$display_name" "$size_hint"; then
        zenity --info \
            --title="${display_name} is Ready" \
            --text="✓ ${display_name} has been installed." \
            --width=300 2>/dev/null || true
        return 0
    fi

    if zenity --question \
            --title="Installation Failed" \
            --text="${display_name} could not be installed.\n\nWould you like to try again?" \
            --ok-label="Try Again" \
            --cancel-label="Skip" \
            --width=380 2>/dev/null; then
        if flatpak install -y --noninteractive flathub "$flatpak_id" \
                >> "${INSTALL_LOG}" 2>&1; then
            log "${display_name} installed on retry."
            return 0
        else
            err "${display_name} install failed on retry."
            return 1
        fi
    else
        err "User declined retry for ${display_name}."
        return 1
    fi
}

# ── Network check first, before asking the user to choose ─────────────────────
# First boot is usually before WiFi is joined. Asking first and checking
# afterwards means an offline user picks a client, waits through a dialog, and
# is then told it cannot be downloaded — and because raptor-firstboot.service
# re-runs until all three stamps exist, writing the stamp on that failure path
# meant they were never asked again and silently got no chat client at all.
# Leave the stamp unwritten so the choice is offered again on the next login.
if ! check_network; then
    log "No network at first boot — chat client choice deferred to next login."
    exit 0
fi

# ── Dialog ────────────────────────────────────────────────────────────────────
CHOICE=$(
    zenity \
        --list \
        --title="Chat Client" \
        --text="<b>Choose a Discord client</b>\n\nBoth connect to Discord — the difference is in what each is optimised for:\n<b>Discord</b> (official) has more reliable Rich Presence support, since game and app integrations are usually built and tested against it first.\n<b>Vesktop</b> is built around Vencord, so plugins, themes, and other customisation work out of the box with no extra setup.\n" \
        --radiolist \
        --column="" \
        --column="Client" \
        --column="Notes" \
        TRUE  "Discord" "Official client · Best Rich Presence support (~150 MB)" \
        FALSE "Vesktop" "Vencord built in · Best for plugins/themes/customisation (~100 MB)" \
        --width=560 --height=340 \
        --ok-label="Confirm" \
        --cancel-label="Skip — Install Neither" \
        2>/dev/null
) || true

# ── Handle choice ─────────────────────────────────────────────────────────────
case "${CHOICE:-}" in

    Discord)
        log "User selected Discord."
        if install_with_retry "com.discordapp.Discord" "Discord" "~150 MB"; then
            finish
        else
            # Do not stamp on a failed download either — otherwise one flaky
            # Flathub fetch costs the user the chat client permanently.
            err "Discord was not installed — choice deferred to next login."
        fi
        ;;

    Vesktop)
        log "User selected Vesktop."
        if install_with_retry "dev.vencord.Vesktop" "Vesktop" "~100 MB"; then
            finish
        else
            err "Vesktop was not installed — choice deferred to next login."
        fi
        ;;

    ""|*)
        # Empty = dismissed dialog or clicked "Skip — Install Neither"
        log "No chat client selected — skipping."
        finish
        ;;
esac
