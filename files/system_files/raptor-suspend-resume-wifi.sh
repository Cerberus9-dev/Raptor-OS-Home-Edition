#!/bin/bash
# raptor-suspend-resume-wifi.sh  (installed as NetworkManager dispatcher 99-raptor-wifi-resume)
#
# After resume, flush stale DNS from the previous network. That is all this
# script does now.
#
# It used to run `nmcli device disconnect` + `connect`. `nmcli device
# disconnect` BLOCKS autoconnect on the device until the user reconnects by
# hand, so whenever the follow-up `connect` failed (AP not yet in range after
# resume) Wi-Fi never came back. It also only fired on the "up" event, i.e.
# only when Wi-Fi had ALREADY reconnected, and left a stale marker file that
# could trigger a disconnect/reconnect cycle at a random later time.
# Reconnection is now handled by /usr/lib/raptor/wifi-recover (resume hook +
# watchdog), which never uses `device disconnect`.

INTERFACE="$1"
ACTION="$2"

if [[ "${INTERFACE}" != wlp* && "${INTERFACE}" != wlan* && "${INTERFACE}" != wlx* ]]; then
    exit 0
fi

if [[ "${ACTION}" == "up" && -f /run/raptor/resume-event ]]; then
    resolvectl flush-caches 2>/dev/null || true
    rm -f /run/raptor/resume-event
fi
exit 0
