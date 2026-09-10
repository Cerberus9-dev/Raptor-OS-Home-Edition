#!/bin/bash
# raptor-suspend-resume-wifi.sh
# NetworkManager dispatcher script: force WiFi reconnection on resume from suspend.
# School/corporate networks often deauthenticate clients during suspend;
# without an explicit cycle, NetworkManager may take 30-60 s to notice and
# reconnect, or fail entirely if the AP dropped the association.

INTERFACE="$1"
ACTION="$2"

# Only act on WiFi interfaces
if [[ "${INTERFACE}" != wlp* && "${INTERFACE}" != wlan* ]]; then
    exit 0
fi

case "${ACTION}" in
    up)
        # Check if this is a resume event (systemd sets a flag)
        if [[ -f /run/raptor/resume-event ]]; then
            logger -t raptor-wifi-resume "Resume detected on ${INTERFACE} — forcing reconnection"
            # Bring the interface down and up to force a fresh association
            nmcli device disconnect "${INTERFACE}" 2>/dev/null || true
            sleep 2
            nmcli device connect "${INTERFACE}" 2>/dev/null || true
            # Also tell systemd-resolved to flush stale DNS cache from the old network
            resolvectl flush-caches 2>/dev/null || true
            rm -f /run/raptor/resume-event
        fi
        ;;
esac

exit 0
