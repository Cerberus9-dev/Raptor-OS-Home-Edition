#!/bin/bash
set -euo pipefail

# =============================================================================
# Raptor OS — laptop hardware recovery (touchpad, Wi-Fi, Bluetooth, mute LEDs)
#
# One build script, one resume hook, one timer. Everything it installs is a
# small helper under /usr/lib/raptor/ — there are no new apps or menu entries.
#
#   /usr/lib/systemd/system-sleep/raptor-resume   runs on every suspend/resume:
#        pre : remember whether Bluetooth was on
#        post: re-bind the touchpad driver, bind mute LEDs, and (detached, so
#              resume is never delayed) recover Wi-Fi and Bluetooth
#   raptor-hardware.timer                         every minute: Wi-Fi watchdog,
#                                                 and bind mute LEDs after boot
#   btusb enable_autosuspend=0                    USB Bluetooth never autosuspends
#
# Recovery never overrides the user (Wi-Fi/Bluetooth turned off on purpose stays
# off) and never uses `nmcli device disconnect`, which blocks autoconnect.
# =============================================================================

mkdir -p /usr/lib/raptor /usr/lib/systemd/system-sleep /usr/lib/modprobe.d

# ── One-time first-login welcome ─────────────────────────────────────────────
cat > /usr/bin/raptor-welcome.sh <<'WELCOME'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/raptor"
STAMP="$STATE_DIR/welcome-done"
[[ -e "$STAMP" ]] && exit 0
mkdir -p "$STATE_DIR"

if ! command -v zenity >/dev/null 2>&1; then
    logger -t raptor-welcome "zenity unavailable; skipping welcome dialog" 2>/dev/null || true
    touch "$STAMP"
    exit 0
fi

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
WELCOME_FILE="$(mktemp "$RUNTIME_DIR/raptor-welcome.XXXXXX")"
trap 'rm -f "$WELCOME_FILE"' EXIT
cat > "$WELCOME_FILE" <<'WELCOME_TEXT'
WELCOME TO RAPTOR OS HOME

A more welcoming, capable desktop — built to make your computer feel like yours again.

THE RAPTOR OS APP SUITE

• Raptor Cortex — understand your hardware, monitor system health, and choose
  power/performance behavior without digging through terminal commands.

• Raptor Update Manager — check for system and application updates in one place.

• Raptor Wallpaper — browse and apply wallpapers from a simple gallery.

• Raptor Music — manage and play your local music library and playlists.

• Shroudly — privacy and connection controls. Features are user-controlled;
  nothing is silently enabled on your behalf.

• Raptor Wine — run many Windows applications through the familiar Wine workflow.
  Compatibility varies by application; some games and protected software may not run.

YOUR COMPUTER, YOUR CHOICES

Raptor OS aims to be lightweight, stable, and understandable. Optional apps are
offered during setup instead of forcing a large software collection onto every PC.

Close or continue whenever you are ready. This welcome screen appears only once
for this user. The setup choices that follow can be skipped and revisited later.
WELCOME_TEXT

zenity --text-info --title="Welcome to Raptor OS Home" \
    --filename="$WELCOME_FILE" --width=760 --height=620 \
    --ok-label="Continue" || true
touch "$STAMP"
WELCOME
chmod 0755 /usr/bin/raptor-welcome.sh
bash -n /usr/bin/raptor-welcome.sh


# ── Wi-Fi: escalating reconnect (resume | watch | force) ─────────────────────
cat << 'WIFI' > /usr/lib/raptor/wifi-recover
#!/bin/bash
# usage: wifi-recover pre|resume|watch|force
MODE="${1:-watch}"
STATE_DIR=/run/raptor
COUNT_FILE="$STATE_DIR/wifi-fail-count"
mkdir -p "$STATE_DIR"
log() { logger -t raptor-wifi "$*" 2>/dev/null || echo "raptor-wifi: $*" >&2; }

# Prevent overlapping timer/resume recovery attempts from fighting each other.
exec 9>"$STATE_DIR/wifi-recover.lock"
flock -n 9 || exit 0

nmcli_status() { timeout 5 nmcli "$@" 2>/dev/null; }
nmcli_status general status >/dev/null || exit 0          # NetworkManager not running
wifi_devs()  { timeout 5 nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1}'; }
dev_state()  { timeout 5 nmcli -t -g GENERAL.STATE device show "$1" 2>/dev/null | head -1; }
connected()  { [[ "$(dev_state "$1")" == 100* ]]; }
busy()       { local s; s="$(dev_state "$1")"; [[ "$s" =~ ^(40|50|60|70|80|90)\  ]]; }
have_profiles() { nmcli_status -t -f TYPE connection show | grep -q '^802-11-wireless
wait_for()   { local d="$1" t="$2"; while (( t > 0 )); do connected "$d" && return 0; sleep 1; t=$((t-1)); done; return 1; }
known_in_range() {
    local known scan
    known="$(timeout 8 nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless" && count++ < 8 {print $1}' |
             while read -r n; do timeout 2 nmcli -g 802-11-wireless.ssid connection show "$n" 2>/dev/null; done)"
    scan="$(timeout 12 nmcli -t -f SSID device wifi list 2>/dev/null | sed 's/\\:/:/g')"
    [[ -n "$known" && -n "$scan" ]] && grep -Fxqf <(printf '%s\n' "$known") <(printf '%s\n' "$scan")
}
scan_empty() { [[ -z "$(timeout 12 nmcli -t -f SSID device wifi list 2>/dev/null | tr -d '[:space:]')" ]]; }

level1() {  # make sure autoconnect is allowed, then ask NM to connect
    local d="$1"; log "L1: re-enable autoconnect and connect $d"
    nmcli_status device set "$d" autoconnect yes || true
    timeout 25 nmcli -w 20 device connect "$d" >/dev/null 2>&1 || true
    wait_for "$d" 5
}
level2() {  # power-cycle the radio
    local d="$1"; log "L2: power-cycling the Wi-Fi radio ($d)"
    timeout 8 nmcli radio wifi off 2>/dev/null || true; sleep 2; timeout 8 nmcli_status radio wifi on || true; sleep 3
    nmcli device set "$d" autoconnect yes 2>/dev/null || true
    wait_for "$d" 25
}
level3() {  # reload the driver
    local d="$1" drv
    drv="$(basename "$(readlink -f "${RAPTOR_SYSFS:-/sys}/class/net/$d/device/driver" 2>/dev/null)" 2>/dev/null)"
    [[ -n "$drv" && "$drv" != "." && "$drv" != "/" ]] || { log "L3: cannot determine driver for $d"; return 1; }
    log "L3: reloading Wi-Fi driver $drv"
    case "$drv" in
        iwlwifi) timeout 10 modprobe -r iwlmvm iwlmld iwlwifi 2>/dev/null; sleep 2; timeout 10 modprobe iwlwifi 2>/dev/null ;;
        *)       timeout 10 modprobe -r "$drv" 2>/dev/null; sleep 2; timeout 10 modprobe "$drv" 2>/dev/null ;;
    esac
    local i=0; until [[ -n "$(wifi_devs)" ]] || (( i++ >= 15 )); do sleep 1; done
    sleep 3
    for nd in $(wifi_devs); do nmcli_status device set "$nd" autoconnect yes || true; done
    d="$(wifi_devs | sed -n '1p')"; [[ -n "$d" ]] && wait_for "$d" 30
}

# Escalate only when there is evidence Wi-Fi SHOULD be working: a known network is
# in range, or the scan list is completely empty (a wedged driver sees nothing).
# If other networks are visible but none of ours, we are simply somewhere else and
# Wi-Fi is working fine -- leave it alone. force mode (manual) skips this check.
worth_escalating() { known_in_range || scan_empty; }

recover() {  # recover <mode> <dev> [stalled]
    local mode="$1" d="$2" stalled="${3:-no}"
    if [[ "$stalled" != yes ]]; then
        level1 "$d" && return 0
    else
        log "$mode: activation remained stuck; skipping another concurrent connect request"
    fi
    if [[ "$mode" != force ]]; then
        timeout 12 nmcli device wifi rescan >/dev/null 2>&1 || true; sleep 4
        worth_escalating || { log "$mode: no known network in range, leaving $d alone"; return 1; }
    fi
    level2 "$d" && return 0
    if [[ "$mode" != force ]]; then
        worth_escalating || { log "$mode: no known network in range after radio cycle, not reloading the driver"; return 1; }
    fi
    if [[ "$mode" == force ]]; then
        level3 "$d"
    else
        log "$mode: radio reset did not recover Wi-Fi; automatic driver reload skipped for safety"
        return 1
    fi
}

# pre: remember whether Wi-Fi was connected before suspend. Recovery after resume
# only ever happens for a link that existed; if the user was on Ethernet or Wi-Fi was
# off, resume must not touch the radio or the driver.
if [[ "$MODE" == pre ]]; then
    st=no
    for d in $(wifi_devs); do connected "$d" && st=yes; done
    echo "$st" > "$STATE_DIR/wifi-was-connected"
    exit 0
fi

for dev in $(wifi_devs); do
    case "$MODE" in
        force)
            nmcli radio wifi on 2>/dev/null || true
            connected "$dev" && { log "force: $dev already connected"; continue; }
            recover force "$dev" && log "force: $dev reconnected" || log "force: $dev still not connected"
            ;;
        resume)
            have_profiles || continue
            [[ "$(nmcli_status radio wifi)" == enabled ]] || continue   # user turned Wi-Fi off
            [[ "$(cat "$STATE_DIR/wifi-was-connected" 2>/dev/null)" == yes ]] || {
                log "resume: Wi-Fi was not connected before suspend, not touching it"; continue; }
            sleep 8                                  # give NetworkManager its normal chance
            n=0; while busy "$dev" && (( n++ < 20 )); do sleep 1; done
            connected "$dev" && continue
            log "resume: $dev not connected after resume"
            if busy "$dev"; then
                recover resume "$dev" yes && log "resume: $dev reconnected" || log "resume: $dev still not connected"
            else
                recover resume "$dev" && log "resume: $dev reconnected" || log "resume: $dev still not connected"
            fi
            ;;
        watch)
            have_profiles || { echo 0 > "$COUNT_FILE"; continue; }
            [[ "$(nmcli radio wifi 2>/dev/null)" == enabled ]] || { echo 0 > "$COUNT_FILE"; continue; }
            if connected "$dev"; then
                touch "$STATE_DIR/wifi-ever-connected"
                echo 0 > "$COUNT_FILE"
                echo 0 > "$STATE_DIR/wifi-busy-count-$dev"
                continue
            fi
            # A connecting/configuring state is not proof of health. Give
            # NetworkManager three timer intervals (about three minutes) to
            # finish, then treat a persistent activation as a stalled attempt.
            stalled=no
            if busy "$dev"; then
                busy_n=$(( $(cat "$STATE_DIR/wifi-busy-count-$dev" 2>/dev/null || echo 0) + 1 ))
                echo "$busy_n" > "$STATE_DIR/wifi-busy-count-$dev"
                if (( busy_n < 3 )); then
                    echo 0 > "$COUNT_FILE"
                    continue
                fi
                log "watch: $dev has remained in an activation state for about three minutes"
                stalled=yes
                echo 0 > "$STATE_DIR/wifi-busy-count-$dev"
            else
                echo 0 > "$STATE_DIR/wifi-busy-count-$dev"
            fi
            # Wi-Fi that never connected this boot (Ethernet-only use, nothing in range)
            # is not "dropped": never escalate on it.
            [[ -e "$STATE_DIR/wifi-ever-connected" ]] || { echo 0 > "$COUNT_FILE"; continue; }
            if [[ "$stalled" == yes ]]; then
                echo 0 > "$COUNT_FILE"
                recover watch "$dev" yes && log "watch: $dev recovered from stalled activation" || log "watch: $dev remains disconnected after bounded recovery"
                continue
            fi
            n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$COUNT_FILE"
            if   (( n == 2 )); then level1 "$dev"
            elif (( n == 4 )) && { known_in_range || scan_empty; }; then level2 "$dev"
            elif (( n >= 8 )); then
                echo 0 > "$COUNT_FILE"
                log "watch: repeated Wi-Fi failures; automatic driver reload is disabled (use explicit recovery if needed)"
            fi
            ;;
    esac
done
exit 0
WIFI
chmod +x /usr/lib/raptor/wifi-recover

# ── Bluetooth: escalating recovery (pre | resume | force) ────────────────────
cat << 'BT' > /usr/lib/raptor/bt-recover
#!/bin/bash
# usage: bt-recover pre|resume|force
MODE="${1:-resume}"
STATE=/run/raptor/bt-was-powered
mkdir -p /run/raptor
log() { logger -t raptor-bt "$*" 2>/dev/null || echo "raptor-bt: $*" >&2; }
command -v bluetoothctl >/dev/null 2>&1 || exit 0

powered() { timeout 5 bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2; exit}'; }
# Querying controller state is passive; never start a discovery scan from a watchdog.
healthy() {
    local info
    info="$(timeout 5 bluetoothctl show 2>/dev/null)" || return 1
    grep -Eq '^Controller [[:xdigit:]:]{17} ' <<<"$info" || return 1
    grep -q '^Powered: yes$' <<<"$info"
}
power_on() { rfkill unblock bluetooth 2>/dev/null; timeout 8 bluetoothctl power on >/dev/null 2>&1; sleep 2; }

case "$MODE" in
    pre)
        p="$(powered)"; echo "${p:-no}" > "$STATE"; exit 0 ;;
    resume)
        [[ "$(cat "$STATE" 2>/dev/null)" == yes ]] || exit 0     # was off on purpose
        sleep 4 ;;
    force) ;;
    *) exit 2 ;;
esac

healthy && { log "$MODE: Bluetooth healthy"; exit 0; }

log "$MODE: L1 unblock + power on"
power_on; healthy && { log "$MODE: recovered at L1"; exit 0; }

log "$MODE: L2 restart bluetooth.service"
systemctl restart bluetooth.service 2>/dev/null; sleep 3; power_on
healthy && { log "$MODE: recovered at L2"; exit 0; }

log "$MODE: L3 reload btusb driver"
systemctl stop bluetooth.service 2>/dev/null
modprobe -r btusb 2>/dev/null; sleep 2; modprobe btusb 2>/dev/null; sleep 3
systemctl start bluetooth.service 2>/dev/null; sleep 3; power_on
healthy && { log "$MODE: recovered at L3"; exit 0; }

log "$MODE: Bluetooth still not working after all recovery steps"
exit 1
BT
chmod +x /usr/lib/raptor/bt-recover

# ── Bluetooth adapter identity ────────────────────────────────────────────────
# Give BlueZ controllers a stable friendly alias so KDE does not expose the
# kernel interface label (for example, hci0) as the adapter's display name.
# This does not delete or rewrite paired-device records: duplicate device rows
# can represent separate BLE/classic identities and must not be pruned blindly.
cat << 'BTNAME' > /usr/lib/raptor/bt-name
#!/bin/bash
set -u
command -v bluetoothctl >/dev/null 2>&1 || exit 0
controllers=""
# bluetooth.service can become active before the controller is enumerated.
# Retry briefly instead of permanently marking this oneshot complete too early.
for attempt in {1..10}; do
    controllers="$(timeout 3 bluetoothctl list 2>/dev/null | awk '/^Controller / {print $2}')"
    [[ -n "$controllers" ]] && break
    sleep 2
done
[[ -n "$controllers" ]] || { echo "No BlueZ controllers appeared; systemd will retry later." >&2; exit 1; }
while IFS= read -r mac; do
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || continue
    printf 'select %s\nsystem-alias Raptor OS Bluetooth\n' "$mac" |
        timeout 8 bluetoothctl >/dev/null 2>&1 || true
done <<< "$controllers"
BTNAME
chmod 0755 /usr/lib/raptor/bt-name

cat << 'BTUNIT' > /usr/lib/systemd/system/raptor-bt-name.service
[Unit]
Description=Set a friendly Raptor OS Bluetooth adapter name
After=bluetooth.service
Wants=bluetooth.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/lib/raptor/bt-name
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
BTUNIT
systemctl enable raptor-bt-name.service 2>/dev/null || true

# ── Mute / mic-mute LEDs: bind the kernel's LEDs to the audio mute state ─────
cat << 'LEDS' > /usr/lib/raptor/leds-sync
#!/bin/bash
# Bind the laptop's mute / mic-mute LEDs to the audio mute state, if the kernel
# exposes them but left them unbound. Safe to run repeatedly.
SYSFS="${RAPTOR_SYSFS:-/sys}"
bind_led() {  # led-dir trigger
    local led="$1" trig="$2" f="$1/trigger"
    [ -w "$f" ] || return 0
    grep -qw "$trig" "$f" || return 0
    grep -q '\[none\]' "$f" || return 0     # only touch unbound LEDs
    echo "$trig" > "$f" 2>/dev/null && logger -t raptor-leds "bound $(basename "$led") -> $trig" 2>/dev/null
}
for led in "$SYSFS"/class/leds/*::mute;    do [ -d "$led" ] && bind_led "$led" audio-mute;    done
for led in "$SYSFS"/class/leds/*::micmute; do [ -d "$led" ] && bind_led "$led" audio-micmute; done
exit 0
LEDS
chmod +x /usr/lib/raptor/leds-sync

# ── Single suspend/resume hook ───────────────────────────────────────────────
# Touchpad: many laptops (HP EliteBook 8xx among them) have an I2C-HID touchpad
# that comes back from suspend half-initialised, so the pointer is dead or barely
# moves. Re-binding its driver re-runs init. General, not model-specific: it finds
# whatever libinput classes as a touchpad and re-binds just that I2C/serio device;
# USB and Bluetooth touchpads are left alone.
cat << 'EOF' > /usr/lib/systemd/system-sleep/raptor-resume
#!/bin/bash
# Raptor OS: runs with "pre|post <what>" from systemd-sleep.
SYSFS="${RAPTOR_SYSFS:-/sys}"
LIB="${RAPTOR_LIB:-/usr/lib/raptor}"
log() { logger -t raptor-resume "$*" 2>/dev/null || echo "raptor-resume: $*" >&2; }

is_touchpad() {
    local ev="$1" name
    if command -v udevadm >/dev/null 2>&1 &&
       udevadm info -q property -p "$ev" 2>/dev/null | grep -q '^ID_INPUT_TOUCHPAD=1'; then
        return 0
    fi
    name="$(cat "$(readlink -f "$ev")/../name" 2>/dev/null || true)"
    [[ "$name" =~ [Tt]ouch[Pp]ad|[Tt]rack[Pp]ad ]]
}

rebind() {  # bus driver device
    local bus="$1" drv="$2" dev="$3" base="$SYSFS/bus/$1/drivers/$2"
    [ -w "$base/unbind" ] && [ -w "$base/bind" ] || return 1
    echo "$dev" > "$base/unbind" 2>/dev/null || true
    sleep 0.3
    echo "$dev" > "$base/bind" 2>/dev/null || return 1
}


rebind_touchpads() {
    sleep 0.5   # let the hardware settle after resume
    declare -A DONE=()
    for ev in "$SYSFS"/class/input/event*; do
        [ -e "$ev" ] || continue
        is_touchpad "$ev" || continue
        dir="$(readlink -f "$ev")"
        while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$SYSFS/devices" ]; do
            if [ -L "$dir/driver" ] && [ -L "$dir/subsystem" ]; then
                sub="$(basename "$(readlink -f "$dir/subsystem")")"
                drv="$(basename "$(readlink -f "$dir/driver")")"
                dev="$(basename "$dir")"
                case "$sub" in
                    i2c)
                        if [ -z "${DONE[$dir]:-}" ]; then
                            DONE[$dir]=1
                            if rebind i2c "$drv" "$dev"; then
                                log "re-bound I2C touchpad $dev ($drv) after resume"
                            else
                                log "could not re-bind I2C touchpad $dev ($drv)"
                            fi
                        fi
                        break ;;
                    serio)
                        if [ -z "${DONE[$dir]:-}" ]; then
                            DONE[$dir]=1
                            if echo reconnect > "$dir/drvctl" 2>/dev/null; then
                                log "reconnected serio touchpad $dev after resume"
                            else
                                log "could not reconnect serio touchpad $dev"
                            fi
                        fi
                        break ;;
                    usb|bluetooth) break ;;
                esac
            fi
            dir="$(dirname "$dir")"
        done
    done
}

case "${1:-}" in
    pre)  "$LIB/bt-recover" pre
          "$LIB/wifi-recover" pre ;;
    post) rebind_touchpads
          "$LIB/leds-sync"
          systemd-run --no-block --quiet --unit="raptor-wifi-resume-$$" "$LIB/wifi-recover" resume
          systemd-run --no-block --quiet --unit="raptor-bt-resume-$$"   "$LIB/bt-recover" resume ;;
esac
exit 0
EOF
chmod +x /usr/lib/systemd/system-sleep/raptor-resume

# ── Timer: Wi-Fi watchdog + LED binding after boot ───────────────────────────
cat << 'EOF' > /usr/lib/systemd/system/raptor-hardware.service
[Unit]
Description=Raptor OS -- Wi-Fi watchdog and mute-LED binding
After=NetworkManager.service sound.target

[Service]
Type=oneshot
ExecStart=-/usr/lib/raptor/leds-sync
ExecStart=-/usr/lib/raptor/wifi-recover watch
EOF
cat << 'EOF' > /usr/lib/systemd/system/raptor-hardware.timer
[Unit]
Description=Raptor OS -- hardware watchdog (every minute)

[Timer]
OnBootSec=45s
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
systemctl enable raptor-hardware.timer 2>/dev/null || true

# USB Bluetooth adapters must never autosuspend: a suspended adapter that fails
# to wake is the usual reason Bluetooth "stays off" or is dead after resume.
cat << 'EOF' > /usr/lib/modprobe.d/raptor-btusb.conf
options btusb enable_autosuspend=0
EOF
; }
wait_for()   { local d="$1" t="$2"; while (( t > 0 )); do connected "$d" && return 0; sleep 1; t=$((t-1)); done; return 1; }
known_in_range() {
    local known scan
    known="$(timeout 8 nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}' |
             while read -r n; do timeout 5 nmcli -g 802-11-wireless.ssid connection show "$n" 2>/dev/null; done)"
    scan="$(timeout 12 nmcli -t -f SSID device wifi list 2>/dev/null | sed 's/\\:/:/g')"
    [[ -n "$known" && -n "$scan" ]] && grep -Fxqf <(printf '%s\n' "$known") <(printf '%s\n' "$scan")
}
scan_empty() { [[ -z "$(nmcli -t -f SSID device wifi list 2>/dev/null | tr -d '[:space:]')" ]]; }

level1() {  # make sure autoconnect is allowed, then ask NM to connect
    local d="$1"; log "L1: re-enable autoconnect and connect $d"
    nmcli device set "$d" autoconnect yes 2>/dev/null || true
    timeout 25 nmcli -w 20 device connect "$d" >/dev/null 2>&1 || true
    wait_for "$d" 5
}
level2() {  # power-cycle the radio
    local d="$1"; log "L2: power-cycling the Wi-Fi radio ($d)"
    timeout 8 nmcli radio wifi off 2>/dev/null || true; sleep 2; timeout 8 nmcli radio wifi on 2>/dev/null || true; sleep 3
    nmcli device set "$d" autoconnect yes 2>/dev/null || true
    wait_for "$d" 25
}
level3() {  # reload the driver
    local d="$1" drv
    drv="$(basename "$(readlink -f "${RAPTOR_SYSFS:-/sys}/class/net/$d/device/driver" 2>/dev/null)" 2>/dev/null)"
    [[ -n "$drv" && "$drv" != "." && "$drv" != "/" ]] || { log "L3: cannot determine driver for $d"; return 1; }
    log "L3: reloading Wi-Fi driver $drv"
    case "$drv" in
        iwlwifi) modprobe -r iwlmvm iwlmld iwlwifi 2>/dev/null; sleep 2; modprobe iwlwifi 2>/dev/null ;;
        *)       modprobe -r "$drv" 2>/dev/null; sleep 2; modprobe "$drv" 2>/dev/null ;;
    esac
    local i=0; until [[ -n "$(wifi_devs)" ]] || (( i++ >= 15 )); do sleep 1; done
    sleep 3
    for nd in $(wifi_devs); do nmcli device set "$nd" autoconnect yes 2>/dev/null || true; done
    d="$(wifi_devs | head -1)"; [[ -n "$d" ]] && wait_for "$d" 30
}

# Escalate only when there is evidence Wi-Fi SHOULD be working: a known network is
# in range, or the scan list is completely empty (a wedged driver sees nothing).
# If other networks are visible but none of ours, we are simply somewhere else and
# Wi-Fi is working fine -- leave it alone. force mode (manual) skips this check.
worth_escalating() { known_in_range || scan_empty; }

recover() {  # recover <mode> <dev> [stalled]
    local mode="$1" d="$2" stalled="${3:-no}"
    if [[ "$stalled" != yes ]]; then
        level1 "$d" && return 0
    else
        log "$mode: activation remained stuck; skipping another concurrent connect request"
    fi
    if [[ "$mode" != force ]]; then
        timeout 12 nmcli device wifi rescan >/dev/null 2>&1 || true; sleep 4
        worth_escalating || { log "$mode: no known network in range, leaving $d alone"; return 1; }
    fi
    level2 "$d" && return 0
    if [[ "$mode" != force ]]; then
        worth_escalating || { log "$mode: no known network in range after radio cycle, not reloading the driver"; return 1; }
    fi
    if [[ "$mode" == force ]]; then
        level3 "$d"
    else
        log "$mode: radio reset did not recover Wi-Fi; automatic driver reload skipped for safety"
        return 1
    fi
}

# pre: remember whether Wi-Fi was connected before suspend. Recovery after resume
# only ever happens for a link that existed; if the user was on Ethernet or Wi-Fi was
# off, resume must not touch the radio or the driver.
if [[ "$MODE" == pre ]]; then
    st=no
    for d in $(wifi_devs); do connected "$d" && st=yes; done
    echo "$st" > "$STATE_DIR/wifi-was-connected"
    exit 0
fi

for dev in $(wifi_devs); do
    case "$MODE" in
        force)
            nmcli radio wifi on 2>/dev/null || true
            connected "$dev" && { log "force: $dev already connected"; continue; }
            recover force "$dev" && log "force: $dev reconnected" || log "force: $dev still not connected"
            ;;
        resume)
            have_profiles || continue
            [[ "$(nmcli radio wifi 2>/dev/null)" == enabled ]] || continue   # user turned Wi-Fi off
            [[ "$(cat "$STATE_DIR/wifi-was-connected" 2>/dev/null)" == yes ]] || {
                log "resume: Wi-Fi was not connected before suspend, not touching it"; continue; }
            sleep 8                                  # give NetworkManager its normal chance
            n=0; while busy "$dev" && (( n++ < 20 )); do sleep 1; done
            connected "$dev" && continue
            log "resume: $dev not connected after resume"
            if busy "$dev"; then
                recover resume "$dev" yes && log "resume: $dev reconnected" || log "resume: $dev still not connected"
            else
                recover resume "$dev" && log "resume: $dev reconnected" || log "resume: $dev still not connected"
            fi
            ;;
        watch)
            have_profiles || { echo 0 > "$COUNT_FILE"; continue; }
            [[ "$(nmcli radio wifi 2>/dev/null)" == enabled ]] || { echo 0 > "$COUNT_FILE"; continue; }
            if connected "$dev"; then
                touch "$STATE_DIR/wifi-ever-connected"
                echo 0 > "$COUNT_FILE"
                echo 0 > "$STATE_DIR/wifi-busy-count-$dev"
                continue
            fi
            # A connecting/configuring state is not proof of health. Give
            # NetworkManager three timer intervals (about three minutes) to
            # finish, then treat a persistent activation as a stalled attempt.
            stalled=no
            if busy "$dev"; then
                busy_n=$(( $(cat "$STATE_DIR/wifi-busy-count-$dev" 2>/dev/null || echo 0) + 1 ))
                echo "$busy_n" > "$STATE_DIR/wifi-busy-count-$dev"
                if (( busy_n < 3 )); then
                    echo 0 > "$COUNT_FILE"
                    continue
                fi
                log "watch: $dev has remained in an activation state for about three minutes"
                stalled=yes
                echo 0 > "$STATE_DIR/wifi-busy-count-$dev"
            else
                echo 0 > "$STATE_DIR/wifi-busy-count-$dev"
            fi
            # Wi-Fi that never connected this boot (Ethernet-only use, nothing in range)
            # is not "dropped": never escalate on it.
            [[ -e "$STATE_DIR/wifi-ever-connected" ]] || { echo 0 > "$COUNT_FILE"; continue; }
            if [[ "$stalled" == yes ]]; then
                echo 0 > "$COUNT_FILE"
                recover watch "$dev" yes && log "watch: $dev recovered from stalled activation" || log "watch: $dev remains disconnected after bounded recovery"
                continue
            fi
            n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$COUNT_FILE"
            if   (( n == 2 )); then level1 "$dev"
            elif (( n == 4 )) && { known_in_range || scan_empty; }; then level2 "$dev"
            elif (( n >= 8 )); then
                echo 0 > "$COUNT_FILE"
                log "watch: repeated Wi-Fi failures; automatic driver reload is disabled (use explicit recovery if needed)"
            fi
            ;;
    esac
done
exit 0
WIFI
chmod +x /usr/lib/raptor/wifi-recover

# ── Bluetooth: escalating recovery (pre | resume | force) ────────────────────
cat << 'BT' > /usr/lib/raptor/bt-recover
#!/bin/bash
# usage: bt-recover pre|resume|force
MODE="${1:-resume}"
STATE=/run/raptor/bt-was-powered
mkdir -p /run/raptor
log() { logger -t raptor-bt "$*" 2>/dev/null || echo "raptor-bt: $*" >&2; }
command -v bluetoothctl >/dev/null 2>&1 || exit 0

powered() { timeout 5 bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2; exit}'; }
# Querying controller state is passive; never start a discovery scan from a watchdog.
healthy() {
    local info
    info="$(timeout 5 bluetoothctl show 2>/dev/null)" || return 1
    grep -Eq '^Controller [[:xdigit:]:]{17} ' <<<"$info" || return 1
    grep -q '^Powered: yes$' <<<"$info"
}
power_on() { rfkill unblock bluetooth 2>/dev/null; timeout 8 bluetoothctl power on >/dev/null 2>&1; sleep 2; }

case "$MODE" in
    pre)
        p="$(powered)"; echo "${p:-no}" > "$STATE"; exit 0 ;;
    resume)
        [[ "$(cat "$STATE" 2>/dev/null)" == yes ]] || exit 0     # was off on purpose
        sleep 4 ;;
    force) ;;
    *) exit 2 ;;
esac

healthy && { log "$MODE: Bluetooth healthy"; exit 0; }

log "$MODE: L1 unblock + power on"
power_on; healthy && { log "$MODE: recovered at L1"; exit 0; }

log "$MODE: L2 restart bluetooth.service"
systemctl restart bluetooth.service 2>/dev/null; sleep 3; power_on
healthy && { log "$MODE: recovered at L2"; exit 0; }

log "$MODE: L3 reload btusb driver"
systemctl stop bluetooth.service 2>/dev/null
modprobe -r btusb 2>/dev/null; sleep 2; modprobe btusb 2>/dev/null; sleep 3
systemctl start bluetooth.service 2>/dev/null; sleep 3; power_on
healthy && { log "$MODE: recovered at L3"; exit 0; }

log "$MODE: Bluetooth still not working after all recovery steps"
exit 1
BT
chmod +x /usr/lib/raptor/bt-recover

# ── Bluetooth adapter identity ────────────────────────────────────────────────
# Give BlueZ controllers a stable friendly alias so KDE does not expose the
# kernel interface label (for example, hci0) as the adapter's display name.
# This does not delete or rewrite paired-device records: duplicate device rows
# can represent separate BLE/classic identities and must not be pruned blindly.
cat << 'BTNAME' > /usr/lib/raptor/bt-name
#!/bin/bash
set -u
command -v bluetoothctl >/dev/null 2>&1 || exit 0
controllers=""
# bluetooth.service can become active before the controller is enumerated.
# Retry briefly instead of permanently marking this oneshot complete too early.
for attempt in {1..10}; do
    controllers="$(timeout 3 bluetoothctl list 2>/dev/null | awk '/^Controller / {print $2}')"
    [[ -n "$controllers" ]] && break
    sleep 2
done
[[ -n "$controllers" ]] || { echo "No BlueZ controllers appeared; systemd will retry later." >&2; exit 1; }
while IFS= read -r mac; do
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || continue
    printf 'select %s\nsystem-alias Raptor OS Bluetooth\n' "$mac" |
        timeout 8 bluetoothctl >/dev/null 2>&1 || true
done <<< "$controllers"
BTNAME
chmod 0755 /usr/lib/raptor/bt-name

cat << 'BTUNIT' > /usr/lib/systemd/system/raptor-bt-name.service
[Unit]
Description=Set a friendly Raptor OS Bluetooth adapter name
After=bluetooth.service
Wants=bluetooth.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/lib/raptor/bt-name
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
BTUNIT
systemctl enable raptor-bt-name.service 2>/dev/null || true

# ── Mute / mic-mute LEDs: bind the kernel's LEDs to the audio mute state ─────
cat << 'LEDS' > /usr/lib/raptor/leds-sync
#!/bin/bash
# Bind the laptop's mute / mic-mute LEDs to the audio mute state, if the kernel
# exposes them but left them unbound. Safe to run repeatedly.
SYSFS="${RAPTOR_SYSFS:-/sys}"
bind_led() {  # led-dir trigger
    local led="$1" trig="$2" f="$1/trigger"
    [ -w "$f" ] || return 0
    grep -qw "$trig" "$f" || return 0
    grep -q '\[none\]' "$f" || return 0     # only touch unbound LEDs
    echo "$trig" > "$f" 2>/dev/null && logger -t raptor-leds "bound $(basename "$led") -> $trig" 2>/dev/null
}
for led in "$SYSFS"/class/leds/*::mute;    do [ -d "$led" ] && bind_led "$led" audio-mute;    done
for led in "$SYSFS"/class/leds/*::micmute; do [ -d "$led" ] && bind_led "$led" audio-micmute; done
exit 0
LEDS
chmod +x /usr/lib/raptor/leds-sync

# ── Single suspend/resume hook ───────────────────────────────────────────────
# Touchpad: many laptops (HP EliteBook 8xx among them) have an I2C-HID touchpad
# that comes back from suspend half-initialised, so the pointer is dead or barely
# moves. Re-binding its driver re-runs init. General, not model-specific: it finds
# whatever libinput classes as a touchpad and re-binds just that I2C/serio device;
# USB and Bluetooth touchpads are left alone.
cat << 'EOF' > /usr/lib/systemd/system-sleep/raptor-resume
#!/bin/bash
# Raptor OS: runs with "pre|post <what>" from systemd-sleep.
SYSFS="${RAPTOR_SYSFS:-/sys}"
LIB="${RAPTOR_LIB:-/usr/lib/raptor}"
log() { logger -t raptor-resume "$*" 2>/dev/null || echo "raptor-resume: $*" >&2; }

is_touchpad() {
    local ev="$1" name
    if command -v udevadm >/dev/null 2>&1 &&
       udevadm info -q property -p "$ev" 2>/dev/null | grep -q '^ID_INPUT_TOUCHPAD=1'; then
        return 0
    fi
    name="$(cat "$(readlink -f "$ev")/../name" 2>/dev/null || true)"
    [[ "$name" =~ [Tt]ouch[Pp]ad|[Tt]rack[Pp]ad ]]
}

rebind() {  # bus driver device
    local bus="$1" drv="$2" dev="$3" base="$SYSFS/bus/$1/drivers/$2"
    [ -w "$base/unbind" ] && [ -w "$base/bind" ] || return 1
    echo "$dev" > "$base/unbind" 2>/dev/null || true
    sleep 0.3
    echo "$dev" > "$base/bind" 2>/dev/null || return 1
}


rebind_touchpads() {
    sleep 0.5   # let the hardware settle after resume
    declare -A DONE=()
    for ev in "$SYSFS"/class/input/event*; do
        [ -e "$ev" ] || continue
        is_touchpad "$ev" || continue
        dir="$(readlink -f "$ev")"
        while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$SYSFS/devices" ]; do
            if [ -L "$dir/driver" ] && [ -L "$dir/subsystem" ]; then
                sub="$(basename "$(readlink -f "$dir/subsystem")")"
                drv="$(basename "$(readlink -f "$dir/driver")")"
                dev="$(basename "$dir")"
                case "$sub" in
                    i2c)
                        if [ -z "${DONE[$dir]:-}" ]; then
                            DONE[$dir]=1
                            if rebind i2c "$drv" "$dev"; then
                                log "re-bound I2C touchpad $dev ($drv) after resume"
                            else
                                log "could not re-bind I2C touchpad $dev ($drv)"
                            fi
                        fi
                        break ;;
                    serio)
                        if [ -z "${DONE[$dir]:-}" ]; then
                            DONE[$dir]=1
                            if echo reconnect > "$dir/drvctl" 2>/dev/null; then
                                log "reconnected serio touchpad $dev after resume"
                            else
                                log "could not reconnect serio touchpad $dev"
                            fi
                        fi
                        break ;;
                    usb|bluetooth) break ;;
                esac
            fi
            dir="$(dirname "$dir")"
        done
    done
}

case "${1:-}" in
    pre)  "$LIB/bt-recover" pre
          "$LIB/wifi-recover" pre ;;
    post) rebind_touchpads
          "$LIB/leds-sync"
          systemd-run --no-block --quiet --unit="raptor-wifi-resume-$$" "$LIB/wifi-recover" resume
          systemd-run --no-block --quiet --unit="raptor-bt-resume-$$"   "$LIB/bt-recover" resume ;;
esac
exit 0
EOF
chmod +x /usr/lib/systemd/system-sleep/raptor-resume

# ── Timer: Wi-Fi watchdog + LED binding after boot ───────────────────────────
cat << 'EOF' > /usr/lib/systemd/system/raptor-hardware.service
[Unit]
Description=Raptor OS -- Wi-Fi watchdog and mute-LED binding
After=NetworkManager.service sound.target

[Service]
Type=oneshot
ExecStart=-/usr/lib/raptor/leds-sync
ExecStart=-/usr/lib/raptor/wifi-recover watch
EOF
cat << 'EOF' > /usr/lib/systemd/system/raptor-hardware.timer
[Unit]
Description=Raptor OS -- hardware watchdog (every minute)

[Timer]
OnBootSec=45s
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
systemctl enable raptor-hardware.timer 2>/dev/null || true

# USB Bluetooth adapters must never autosuspend: a suspended adapter that fails
# to wake is the usual reason Bluetooth "stays off" or is dead after resume.
cat << 'EOF' > /usr/lib/modprobe.d/raptor-btusb.conf
options btusb enable_autosuspend=0
EOF
