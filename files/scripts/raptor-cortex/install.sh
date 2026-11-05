#!/bin/bash
set -e

# =============================================================================
# Raptor Cortex v4.2 — Unified Memory & Performance Management
# • RAM optimization with page cache management, compaction, zram recompress
# • Background service trimming/restoring for gaming
# • Seamless performance mode switching (no login required)
# • Game mode auto-suspend/resume via Cortex patterns
# • Power Profiles integration (KDE Powerdevil remains the CPU-policy owner)
# • Per-mode kernel tuning (power/balanced/performance)
# • Battery slider passthrough via power-profiles-daemon
# • PCIe ASPM, NVMe power states, USB autosuspend, runtime PM
# =============================================================================

# ── Custom icon ───────────────────────────────────────────────────────────────
mkdir -p /usr/share/icons/hicolor/scalable/apps
cat << 'SVGEOF' > /usr/share/icons/hicolor/scalable/apps/raptor-cortex.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#7c3aed"/>
      <stop offset="100%" stop-color="#4c1d95"/>
    </radialGradient>
    <radialGradient id="core" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#c4b5fd"/>
      <stop offset="100%" stop-color="#7c3aed"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="url(#bg)"/>
  <circle cx="32" cy="32" r="24" fill="none" stroke="#a78bfa" stroke-width="1.5"
          stroke-dasharray="12 4" stroke-linecap="round"/>
  <line x1="32" y1="10" x2="32" y2="18" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="32" y1="46" x2="32" y2="54" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="10" y1="32" x2="18" y2="32" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="46" y1="32" x2="54" y2="32" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="16.7" y1="16.7" x2="22.4" y2="22.4" stroke="#c4b5fd" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="41.6" y1="41.6" x2="47.3" y2="47.3" stroke="#c4b5fd" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="47.3" y1="16.7" x2="41.6" y2="22.4" stroke="#c4b5fd" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="22.4" y1="41.6" x2="16.7" y2="47.3" stroke="#c4b5fd" stroke-width="1.5" stroke-linecap="round"/>
  <circle cx="32" cy="32" r="9" fill="url(#core)"/>
  <path d="M 29 26 L 35 26 L 33 31 L 36 31 L 29 40 L 31 33 L 28 33 Z"
        fill="white" opacity="0.95"/>
</svg>
SVGEOF

gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── Privileged helper ─────────────────────────────────────────────────────────
mkdir -p /usr/lib/raptor

cat << 'EOF' > /usr/lib/raptor/cortex-helper
#!/bin/bash
# Args: CACHE COMPACT ZRAM OOM DEEP SWAP THP CPU | trim-background |
#       restore-background | set-mode <power_saving|balanced|performance>
ACTION="${1:-help}"
GAME_MODE_MARKER="/run/raptor-game-mode-active"
GAME_MODE_PROCS_FILE="/run/raptor-game-mode-procs"

# ── Suspended process set ─────────────────────────────────────────────────────
# Single source of truth for both trim-background and restore-background.
# These two MUST stay identical: any process stopped here and not CONT'd there
# stays SIGSTOP'd for the rest of the session (until reboot). Previously the two
# lists drifted and 7 processes were left frozen permanently.
#
# Package managers, communications, user applications, audio, and device
# services are deliberately excluded from Game Mode suspension.
BACKGROUND_PROCS=(
    # Indexing, thumbnail generation, and the KDE crash reporter only.
    # Keep communications, audio, package management, printers, storage
    # maintenance, and user applications running.
    "tracker-miner" "tracker-store" "tracker3"
    "baloo_file" "baloo_file_extractor" "kio_thumbnail"
    "zeitgeist" "tumblerd" "updatedb" "mlocate" "drkonqi"
)

# ── Hardware power helpers ────────────────────────────────────────────────────

# True when running from mains / USB-C power, or when there is no battery
# (desktop). Used so battery-draining gaming tweaks never run on battery.
_on_ac() {
    local s t found=0 online=0
    for s in /sys/class/power_supply/*; do
        t=$(cat "$s/type" 2>/dev/null) || continue
        case "$t" in
            Mains|USB|USB_C|USB_PD|USB_PD_DRP|USB_DCP|USB_CDP|USB_ACA)
                found=1
                [ "$(cat "$s/online" 2>/dev/null)" = "1" ] && online=1 ;;
        esac
    done
    [ "$found" = "0" ] && return 0
    [ "$online" = "1" ]
}

_apply_pcie_aspm() {
    # powersave | performance | default
    local P="$1"
    [ -f /sys/module/pcie_aspm/parameters/policy ] && \
        echo "$P" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
}

_apply_nvme_power() {
    # Linux runtime-PM power/control accepts only "auto" or "on".
    # NVMe APST policy is a separate controller setting and is not changed here.
    local state="$1" f
    case "$state" in
        auto|on) ;;
        *) echo "Invalid NVMe runtime-PM mode: $state" >&2; return 2 ;;
    esac
    for f in /sys/class/nvme/nvme*/power/control; do
        [ -w "$f" ] || continue
        printf '%s\n' "$state" > "$f" 2>/dev/null || true
    done
}

_apply_usb_autosuspend() {
    # 1 = enable (power save), 0 = disable (performance)
    #
    # Skips any device (or interface) bound to btusb (Bluetooth adapters),
    # usbhid (USB keyboards/mice/HID), or snd-usb-audio (USB audio devices —
    # this covers wireless headset/gaming dongles, which almost always
    # enumerate as a USB audio device regardless of the RF protocol they use
    # internally). The previous version only excluded btusb/usbhid, missing
    # this class entirely — applying autosuspend to a USB audio device mid-
    # stream is a well-known cause of exactly the kind of crackling/dropout
    # this was producing.
    local mode="$1"
    for dev_path in /sys/bus/usb/devices/*/; do
        dev_path="${dev_path%/}"
        [ -f "$dev_path/power/control" ] || continue

        local skip=0
        for drv_link in "$dev_path"/*/driver "$dev_path/driver"; do
            [ -L "$drv_link" ] || continue
            local drv_name
            drv_name=$(basename "$(readlink -f "$drv_link")" 2>/dev/null)
            if [ "$drv_name" = "btusb" ] || [ "$drv_name" = "usbhid" ] || [ "$drv_name" = "snd-usb-audio" ]; then
                skip=1
                break
            fi
        done
        [ "$skip" = "1" ] && continue

        if [ "$mode" = "1" ]; then
            echo 2000 > "$dev_path/power/autosuspend_delay_ms" 2>/dev/null || true
            echo auto > "$dev_path/power/control" 2>/dev/null || true
        else
            echo on > "$dev_path/power/control" 2>/dev/null || true
        fi
    done
}

_apply_runtime_pm() {
    # auto | on
    local P="$1"
    for f in /sys/bus/pci/devices/*/power/control; do
        # Network (0x02xxxx) and wireless-controller (0x0dxxxx) PCI devices are
        # ALWAYS kept awake: runtime-suspending a Wi-Fi/Bluetooth card is a known
        # cause of dropouts and of "never reconnects after resume" (mt7921e,
        # rtw89, ath11k and others). The saving is a fraction of a watt.
        local cls
        cls=$(cat "${f%/power/control}/class" 2>/dev/null || echo 0)
        # Keep network, wireless, and multimedia/audio controllers awake.
        # Runtime-suspending PCI audio hardware can create wake-up pops or
        # intermittent device loss on some laptop chipsets.
        case "$cls" in
            0x02*|0x04*|0x0d*) echo on > "$f" 2>/dev/null || true; continue ;;
        esac
        echo "$P" > "$f" 2>/dev/null || true
    done
}

_apply_sata_link_power() {
    # min_power | medium_power | max_performance
    local P="$1"
    for f in /sys/class/scsi_host/host*/link_power_management_policy; do
        echo "$P" > "$f" 2>/dev/null || true
    done
}

# CPU governor, boost, EPP, frequency caps and firmware platform profile
# are exclusively managed by power-profiles-daemon. Do not write those sysfs
# controls from Cortex; KDE Powerdevil must remain free to change them.

_apply_net_runtime_pm() {
    # Enable runtime power management for network devices.
    # This powers down the NIC hardware when idle — does NOT disconnect WiFi.
    # The driver keeps the association; the radio powers down between packets.
    local MODE="$1"   # auto | on
    for dev in /sys/class/net/*/device/power/control; do
        # Wireless NICs are always kept awake (see _apply_runtime_pm); only
        # wired NICs are runtime-suspended.
        local netdir
        netdir="${dev%/device/power/control}"
        if [ -d "$netdir/wireless" ] || [ -d "$netdir/phy80211" ]; then
            echo on > "$dev" 2>/dev/null || true
            continue
        fi
        echo "$MODE" > "$dev" 2>/dev/null || true
    done
}

_apply_audio_powersave() {
    # 1 or 0
    for f in /sys/module/snd_hda_intel/parameters/power_save \
              /sys/module/snd_ac97_codec/parameters/power_save; do
        [ -f "$f" ] && echo "$1" > "$f" 2>/dev/null || true
    done
}

# ── Pressure-aware cgroup v2 reclaim ─────────────────────────────────────────
# The kernel already manages useful file/page caches; flushing them makes
# games reload data from storage and can create stutter. Only ask user.slice
# to reclaim a small amount when MemAvailable is genuinely low. Never touch
# the root cgroup, which would include system services and unrelated tasks.
_reclaim_user_slice() {
    # Reclaim only when the machine is genuinely under memory pressure.
    # One write at user.slice covers descendants; repeated nested writes can
    # multiply reclaim and evict active applications unnecessarily.
    local amount="${1:-268435456}"  # 256 MiB maximum request
    local total_kb available_kb threshold_kb
    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
    [[ "$total_kb" =~ ^[0-9]+$ && "$available_kb" =~ ^[0-9]+$ ]] || return 0
    threshold_kb=$(( total_kb / 10 ))
    [ "$threshold_kb" -lt 524288 ] && threshold_kb=524288
    [ "$available_kb" -ge "$threshold_kb" ] && return 0

    local f
    for f in /sys/fs/cgroup/user.slice/memory.reclaim \
             /sys/fs/cgroup/user.slice/user-*.slice/memory.reclaim; do
        if [ -w "$f" ]; then
            echo "$amount" > "$f" 2>/dev/null || true
            break
        fi
    done
    return 0
}

# FIX: clear Powerdevil session action so switching to power-saver
# doesn't trigger a logout/suspend. Patches every user's config and
# tells the running daemon to reload.
# Powerdevil owns lid, idle, suspend and button actions. Cortex must never
# rewrite a user's power-management configuration or disable their sleep policy.

case "$ACTION" in
    # ── RAM optimization flags ─────────────────────────────────────────────
    0|1|2|3|4|5|6|7|8)
        DO_CACHE="${1:-0}";  DO_COMPACT="${2:-0}"; DO_ZRAM="${3:-0}"
        DO_OOM="${4:-0}";    DO_DEEP="${5:-0}";    DO_SWAP="${6:-0}"
        DO_THP="${7:-0}";    DO_CPU="${8:-0}"

        if [ "$DO_CACHE" = "1" ]; then
            # Keep useful file/game caches; reclaim only under real pressure.
            _reclaim_user_slice 268435456
        fi
        [ "$DO_COMPACT" = "1" ] && echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
        if [ "$DO_ZRAM" = "1" ] && [ -w /sys/block/zram0/recompress ]; then
            # Recompress a bounded number of idle pages only. No backing device
            # is configured, so writeback is deliberately never requested.
            echo all > /sys/block/zram0/idle 2>/dev/null || true
            echo "type=idle max_pages=128" > /sys/block/zram0/recompress 2>/dev/null || true
        fi
        if [ "$DO_OOM" = "1" ]; then
            for proc in plasmashell kwin_wayland kwin_x11 ksmserver kded6; do
                for pid in $(pgrep -x "$proc" 2>/dev/null || true); do
                    echo -800 > /proc/$pid/oom_score_adj 2>/dev/null || true
                done
            done
            for proc in chrome chromium brave firefox; do
                for pid in $(pgrep -x "$proc" 2>/dev/null || true); do
                    echo 300 > /proc/$pid/oom_score_adj 2>/dev/null || true
                done
            done
        fi
        if [ "$DO_DEEP" = "1" ]; then
            # Deep reclaim remains pressure-aware and capped. Do not toggle THP,
            # NUMA balancing, or discard useful page cache as a "cleanup".
            _reclaim_user_slice 536870912
        fi
        if [ "$DO_SWAP" = "1" ]; then
            # Do not temporarily rewrite global swappiness; ask the kernel for
            # bounded reclaim only if the same low-memory threshold is crossed.
            _reclaim_user_slice 536870912
        fi
        if [ "$DO_THP" = "1" ]; then
            echo madvise       > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
            echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
        fi
        # CPU boost is controlled by power-profiles-daemon, never by Cortex's
        # memory-optimization path.
        ;;

    # ── Per-mode kernel tuning ─────────────────────────────────────────────
    set-mode)
        MODE="${2:-balanced}"
        case "$MODE" in
            power_saving|balanced|performance) ;;
            *) echo "Invalid Cortex mode: $MODE" >&2; exit 2 ;;
        esac

        # CPU policy is deliberately owned by power-profiles-daemon (PPD).
        # KDE Powerdevil's battery slider and Cortex both talk to that same
        # service. Cortex must not write scaling_governor, EPP, boost, or
        # scaling_max_freq directly: doing so races PPD and makes the tray
        # profile appear stuck or immediately revert. The mode below selects
        # the matching PPD profile; Cortex only tunes independent devices.
        command -v powerprofilesctl >/dev/null 2>&1 || {
            echo "powerprofilesctl is required; refusing to apply a partial power mode" >&2
            exit 1
        }

        case "$MODE" in
            power_saving) PPD_PROFILE="power-saver" ;;
            balanced)     PPD_PROFILE="balanced" ;;
            performance)  PPD_PROFILE="performance" ;;
        esac
        # Fail before touching device/kernel settings if the requested profile
        # is not exposed by this machine's power-profiles-daemon backend.
        if ! timeout 10s powerprofilesctl set "$PPD_PROFILE"; then
            echo "Unable to activate power profile '$PPD_PROFILE'; check supported profiles and power-profiles-daemon" >&2
            exit 1
        fi
        ACTUAL_PROFILE="$(timeout 5s powerprofilesctl get 2>/dev/null)" || {
            echo "Could not verify the active Power Profiles selection" >&2
            exit 1
        }
        if [ "$ACTUAL_PROFILE" != "$PPD_PROFILE" ]; then
            echo "Power Profiles mismatch: requested $PPD_PROFILE, active $ACTUAL_PROFILE" >&2
            exit 1
        fi

        case "$MODE" in
            power_saving)
                # Leave all Powerdevil idle, suspend, lid and button settings
                # untouched; the desktop power manager owns those actions.
                echo 100  > /proc/sys/vm/swappiness                2>/dev/null || true
                echo 5    > /proc/sys/vm/dirty_ratio               2>/dev/null || true
                echo 2    > /proc/sys/vm/dirty_background_ratio    2>/dev/null || true
                # Conservative writeback intervals avoid large dirty-page buildup
                # and long flush bursts while retaining reasonable idle periods.
                echo 5000  > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
                echo 30000 > /proc/sys/vm/dirty_expire_centisecs    2>/dev/null || true
                # Avoid legacy laptop_mode write deferral on modern NVMe systems.
                echo 0 > /proc/sys/vm/laptop_mode 2>/dev/null || true

                # PPD owns CPU governor, boost, EPP, frequency limits, and
                # firmware platform profile so KDE's battery slider stays live.
                echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

                _apply_pcie_aspm       powersave
                _apply_nvme_power      auto
                _apply_usb_autosuspend 1
                _apply_runtime_pm      auto
                _apply_sata_link_power min_power
                # Keep audio codec power-save disabled in Balanced mode to avoid
                # wake-up clicks, delayed audio, and device transition glitches.
                _apply_audio_powersave 0

                # Keep the HDA controller awake as well; audio reliability takes
                # priority over the small idle-power saving in this profile.
                echo N > /sys/module/snd_hda_intel/parameters/power_save_controller 2>/dev/null || true

                # Network device runtime PM: powers down NIC hardware between packets.
                # Does NOT disconnect WiFi — the driver keeps the association alive;
                # only the radio hardware powers down during idle periods.
                _apply_net_runtime_pm auto

                # Wi-Fi / Bluetooth power save is deliberately NOT forced on here.
                # 802.11 power save and Bluetooth sniff/park modes cause missed
                # reconnects, dropped links and dead adapters after resume on many
                # laptops. NetworkManager owns Wi-Fi power save (wifi.powersave=2 in
                # 91-raptor-network.conf) and BlueZ owns Bluetooth link policy.

                # Display backlight is deliberately NOT touched here. This used to write
                # 50% of max straight into /sys/class/backlight every time the mode was
                # applied (boot, plug/unplug) and never restored it: it overrode the
                # user's chosen brightness, desynced KDE PowerDevil (so the brightness
                # keys and slider acted on a stale value) and left the screen dim after
                # leaving power-saving. PowerDevil already dims on battery per the
                # user's own Plasma power settings.

                ;;

            balanced)
                # ZRAM is fast compressed RAM; allow it to absorb cold pages
                # before the system approaches OOM on low-memory machines.
                echo 100  > /proc/sys/vm/swappiness                2>/dev/null || true
                echo 10   > /proc/sys/vm/dirty_ratio               2>/dev/null || true
                echo 5    > /proc/sys/vm/dirty_background_ratio    2>/dev/null || true
                echo 1500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
                echo 1500 > /proc/sys/vm/dirty_expire_centisecs    2>/dev/null || true
                echo 0    > /proc/sys/vm/laptop_mode               2>/dev/null || true

                # PPD owns CPU and firmware policy; Balanced remains its
                # native profile rather than a second set of competing writes.
                echo madvise       > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
                echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

                _apply_pcie_aspm       default
                _apply_nvme_power      auto
                _apply_usb_autosuspend 1
                _apply_runtime_pm      auto
                _apply_sata_link_power medium_power
                # Keep codec and controller awake in Balanced mode to avoid
                # power-state transitions during quiet audio or device wake-up.
                _apply_audio_powersave 0
                echo N > /sys/module/snd_hda_intel/parameters/power_save_controller 2>/dev/null || true
                _apply_net_runtime_pm on

                ;;

            performance)
                # Keep ZRAM available under pressure instead of forcing OOM.
                # Modest dirty-page limits avoid large flush bursts during play.
                echo 80  > /proc/sys/vm/swappiness                 2>/dev/null || true
                echo 10  > /proc/sys/vm/dirty_ratio                2>/dev/null || true
                echo 5   > /proc/sys/vm/dirty_background_ratio     2>/dev/null || true
                echo 500 > /proc/sys/vm/dirty_writeback_centisecs  2>/dev/null || true
                echo 500 > /proc/sys/vm/dirty_expire_centisecs     2>/dev/null || true
                echo 0   > /proc/sys/vm/laptop_mode                2>/dev/null || true

                # PPD owns CPU and firmware policy, including boost and EPP.
                # Restore audio controller and net PM to full power
                echo N > /sys/module/snd_hda_intel/parameters/power_save_controller                     2>/dev/null || true
                _apply_net_runtime_pm on
                echo 500 > /proc/sys/vm/dirty_writeback_centisecs  2>/dev/null || true
                echo 500 > /proc/sys/vm/dirty_expire_centisecs     2>/dev/null || true
                echo 0   > /proc/sys/vm/laptop_mode                2>/dev/null || true

                echo madvise       > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
                echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

                _apply_pcie_aspm       performance
                _apply_nvme_power      on
                _apply_usb_autosuspend 0
                _apply_runtime_pm      on
                _apply_sata_link_power max_performance
                _apply_audio_powersave 0

                # Avoid cache drops and memory compaction on mode switches:
                # both can cause avoidable I/O or CPU spikes during game launch.
                ;;
        esac
        ;;

    # ── Background trimming for gaming ─────────────────────────────────────
    trim-background)
        # Idempotent: Cortex's button, manual Performance mode and GameMode's
        # start hook can all arrive for the same session. Never overwrite the
        # first session's restore list or a process could remain SIGSTOP'd.
        if [ -f "$GAME_MODE_MARKER" ]; then
            echo "Raptor Game Mode background trim is already active."
            exit 0
        fi
        # Pause only optional indexers selected in the Cortex UI. Never flush
        # caches, compact memory, stop irqbalance, or stop system services.
        touch "$GAME_MODE_MARKER"
        : > "$GAME_MODE_PROCS_FILE"
        for proc in "${BACKGROUND_PROCS[@]}"; do
            if { [ ! -f /etc/raptor/cortex-suspend.conf ] || grep -Fxq "$proc" /etc/raptor/cortex-suspend.conf; } &&
               pgrep -x "$proc" >/dev/null 2>&1; then
                /usr/lib/raptor/safe-signal STOP "$proc"
                printf '%s\n' "$proc" >> "$GAME_MODE_PROCS_FILE"
            fi
        done
        if [ -f /etc/raptor/cortex-suspend.conf ] && grep -Fxq "baloo_file" /etc/raptor/cortex-suspend.conf; then
            if balooctl6 suspend 2>/dev/null || balooctl suspend 2>/dev/null; then
                touch /run/raptor-game-mode-baloo-active
            fi
        fi
        # Only hold the CPU wake-latency constraint on AC; release on restore.
        rm -f /run/raptor-cpu-dma-latency-held
        if _on_ac && [ -w /dev/cpu_dma_latency ]; then
            (
                exec 9<>/dev/cpu_dma_latency
                echo 0x32 >&9
                touch /run/raptor-cpu-dma-latency-held
                while [ -f /run/raptor-cpu-dma-latency-held ] && _on_ac; do sleep 5; done
                rm -f /run/raptor-cpu-dma-latency-held
            ) &>/dev/null &
            disown
        fi
        ;;

    # ── Background restoration after gaming ────────────────────────────────
    restore-background)
        # A mode switch at boot must not send SIGCONT to unrelated processes.
        # Only restore work if this session actually entered Game Mode.
        if [ ! -f "$GAME_MODE_MARKER" ]; then
            rm -f /run/raptor-cpu-dma-latency-held "$GAME_MODE_PROCS_FILE"
            exit 0
        fi
        # Resume only process patterns recorded by this Game Mode session.
        if [ -f "$GAME_MODE_PROCS_FILE" ]; then
            while IFS= read -r proc; do
                [ -n "$proc" ] && /usr/lib/raptor/safe-signal CONT "$proc"
            done < "$GAME_MODE_PROCS_FILE"
            rm -f "$GAME_MODE_PROCS_FILE"
        fi
        if [ -f /run/raptor-game-mode-baloo-active ]; then
            balooctl6 resume 2>/dev/null || balooctl resume 2>/dev/null || true
            rm -f /run/raptor-game-mode-baloo-active
        fi
        # Release the AC-only CPU wake-latency constraint.
        rm -f /run/raptor-cpu-dma-latency-held "$GAME_MODE_MARKER"
        ;;

    *)
        echo "Usage: cortex-helper [CACHE COMPACT ZRAM OOM DEEP SWAP THP CPU] | set-mode <power_saving|balanced|performance> | trim-background | restore-background"
        exit 1
        ;;
esac
exit 0
EOF
chmod +x /usr/lib/raptor/cortex-helper

# ── Sudoers ───────────────────────────────────────────────────────────────────
mkdir -p /etc/sudoers.d
cat << 'EOF' > /etc/sudoers.d/raptor-cortex
ALL ALL=(root) NOPASSWD: /usr/lib/raptor/cortex-helper
EOF
chmod 440 /etc/sudoers.d/raptor-cortex || true
if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf /etc/sudoers.d/raptor-cortex; then
        echo "FATAL: /etc/sudoers.d/raptor-cortex is invalid — refusing to ship a" >&2
        echo "       broken rule set. sudo ignores a malformed drop-in entirely," >&2
        echo "       which would make every cortex-helper call fail for all users." >&2
        exit 1
    fi
else
    echo "WARNING: visudo unavailable — /etc/sudoers.d/raptor-cortex NOT validated" >&2
fi

# ── Apply the persisted mode at boot ──────────────────────────────────────────
# The GUI's "Apply selected mode on every boot" toggle only ever wrote
# ~/.config/raptor-cortex-mode; nothing read it at startup, so the mode was
# lost on every reboot and the CPU governor was instead set by gpu-detect.sh
# according to the *GPU profile*. This applies it.
cat << 'EOF' > /usr/lib/raptor/cortex-apply-boot-mode
#!/bin/bash
# Re-apply the user's persisted Raptor Cortex performance mode at login.
HELPER=${RAPTOR_CORTEX_HELPER:-/usr/lib/raptor/cortex-helper}
MODE_FILE="$HOME/.config/raptor-cortex-mode"
SETTINGS_FILE="$HOME/.config/raptor-cortex-settings.json"

# Respect the user's "apply mode on boot" preference. Default is on, matching
# the GUI's own default. Parsed without a JSON dependency.
if [ -f "$SETTINGS_FILE" ] && grep -q '"auto_apply_mode_on_boot"[[:space:]]*:[[:space:]]*false' "$SETTINGS_FILE"; then
    exit 0
fi

[ -f "$MODE_FILE" ] || exit 0
MODE=$(tr -d '[:space:]' < "$MODE_FILE")

# Only ever pass a known-good value to the helper.
case "$MODE" in
    power_saving|balanced|performance) ;;
    *) exit 0 ;;
esac

[ -x "$HELPER" ] || exit 0
sudo -n "$HELPER" set-mode "$MODE" >/dev/null 2>&1
EOF
chmod +x /usr/lib/raptor/cortex-apply-boot-mode

cat << 'EOF' > /usr/lib/systemd/user/raptor-cortex-mode.service
[Unit]
Description=Raptor Cortex — apply persisted power profile
# power-profiles-daemon is the sole CPU-policy owner; this user unit only
# applies the user's selected PPD profile after the desktop session starts.
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=/usr/lib/raptor/cortex-apply-boot-mode
# A failure must not mark the user's session as failed.
SuccessExitStatus=0 1

[Install]
WantedBy=default.target
EOF

# ── Cortex suspend config ─────────────────────────────────────────────────────
mkdir -p /etc/raptor
cat << 'EOF' > /etc/raptor/cortex-suspend.conf
# Raptor Cortex — optional background work to pause during gaming.
# This includes indexers, thumbnail generation and KDE crash reporting.
# Audio, networking, Bluetooth, package management, storage maintenance,
# communications, and user applications remain available.
baloo_file
baloo_file_extractor
tracker-miner
tracker-store
tracker3
kio_thumbnail
zeitgeist
tumblerd
updatedb
mlocate
drkonqi
EOF

# -- Safe freeze / unfreeze helpers ---------------------------------------------
# Raptor used to SIGSTOP processes by *substring* name match. That froze things
# every KDE/GTK/Chromium app talks to (kded, kwalletd, kactivitymanagerd, gvfs),
# and froze single-instance apps (Firefox, Discord, Steam...) so that launching
# them again just handed off to the frozen copy: "all apps randomly fail to
# open". These helpers (1) refuse to freeze session-critical processes and
# (2) un-freeze anything left frozen.
mkdir -p /usr/lib/raptor
cat << 'EOF' > /usr/lib/raptor/safe-signal
#!/bin/bash
# usage: safe-signal STOP|CONT name [name...]
# Matches the process *name* (comm) by prefix, never by substring or full
# command line. STOP is refused for session-critical processes.
SIG="${1:-}"; shift || true
case "$SIG" in STOP|CONT) ;; *) echo "usage: $0 STOP|CONT name..." >&2; exit 2 ;; esac
PROTECTED=(kded kwalletd kactivitymanagerd kglobalaccel kwin plasma ksmserver
           krunner kscreen kio_ gvfs dbus systemd xdg- pipewire wireplumber
           pulseaudio polkit Xwayland sddm gamemode sudo pkexec bwrap flatpak
           steam pressure-vessel srt- raptor- python bash sh login
           firefox chrome chromium brave vivaldi opera msedge vesktop discord
           spotify telegram signal slack element thunderbird)
is_protected() { local p; for p in "${PROTECTED[@]}"; do [[ "$1" == "$p"* ]] && return 0; done; return 1; }
while read -r pid comm; do
    [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    for pat in "$@"; do
        [[ -z "$pat" ]] && continue
        if [[ "$comm" == "${pat:0:15}"* ]]; then
            if [[ "$SIG" == STOP ]] && is_protected "$comm"; then break; fi
            kill -"$SIG" "$pid" 2>/dev/null || true
            break
        fi
    done
done < <(ps -eo pid=,comm=)
exit 0
EOF
chmod +x /usr/lib/raptor/safe-signal

cat << 'EOF' > /usr/lib/raptor/unfreeze
#!/bin/bash
# Resume critical apps immediately, then recover old Raptor freezes once per boot.
PROTECTED=(kded kwalletd kactivitymanagerd kglobalaccel kwin plasma ksmserver
           krunner kscreen gvfs dbus xdg- pipewire wireplumber pulseaudio
           polkit Xwayland firefox chrome chromium brave vivaldi opera msedge
           vesktop discord spotify telegram signal slack element thunderbird
           steam)
KNOWN=(baloo tracker akonadi kdeconnectd zeitgeist tumblerd updatedb mlocate
       snapd evolution gnome-software packagekitd drkonqi obexd pcscd
       cups-browsed colord plasma-geolocation kio_thumbnail)
[ -f /etc/raptor/cortex-suspend.conf ] && while IFS= read -r l; do
    [[ -z "$l" || "${l:0:1}" == "#" ]] || KNOWN+=("$l")
done < /etc/raptor/cortex-suspend.conf

gaming=0
# Do not undo an active Cortex or standalone gaming-trimmer session.
[ -e /run/raptor-game-mode-active ] && gaming=1
[ -e /run/raptor-gaming-trim-active ] && gaming=1
[ -e /run/raptor-cpu-dma-latency-held ] && gaming=1
if command -v gamemoded >/dev/null 2>&1 && gamemoded -s 2>/dev/null | grep -qi "is active"; then
    gaming=1
fi

match() {
    local c="$1" p
    shift
    for p in "$@"; do [[ "$c" == "${p:0:15}"* ]] && return 0; done
    return 1
}

need_root=0
LEGACY_STAMP="/run/raptor-unfreeze-legacy-recovered"
legacy_recovery=0
# Previous releases froze a broader list. Recover those processes once, after
# any active game ends; current Game Mode uses its own exact per-session list.
if [[ "$gaming" -eq 0 && ! -e "$LEGACY_STAMP" ]]; then
    legacy_recovery=1
fi

while read -r pid stat comm uid; do
    [[ "$stat" == T* ]] || continue
    if match "$comm" "${PROTECTED[@]}"; then
        kill -CONT "$pid" 2>/dev/null || true
    elif [[ "$legacy_recovery" -eq 1 ]] && match "$comm" "${KNOWN[@]}"; then
        if [[ "$uid" == "$(id -u)" ]]; then
            kill -CONT "$pid" 2>/dev/null || true
        else
            need_root=1
        fi
    fi
done < <(ps -eo pid=,stat=,comm=,uid=)

[[ "$legacy_recovery" -eq 1 ]] && touch "$LEGACY_STAMP"
[[ "$need_root" -eq 1 ]] && sudo -n /usr/lib/raptor/cortex-helper restore-background >/dev/null 2>&1
exit 0
EOF
chmod +x /usr/lib/raptor/unfreeze

cat << 'EOF' > /usr/lib/systemd/user/raptor-unfreeze.service
[Unit]
Description=Raptor: resume anything left frozen

[Service]
Type=oneshot
ExecStart=/usr/lib/raptor/unfreeze
EOF
cat << 'EOF' > /usr/lib/systemd/user/raptor-unfreeze.timer
[Unit]
Description=Raptor: periodically resume frozen apps and services

[Timer]
OnStartupSec=20
OnUnitActiveSec=2min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
systemctl --global enable raptor-unfreeze.timer 2>/dev/null || true

# ── Gamemode hooks ────────────────────────────────────────────────────────────
cat << 'EOF' > /usr/lib/raptor/gamemode-start
#!/bin/bash
# Single source of truth: Cortex pauses only configured optional indexers and
# applies its bounded AC-only wake-latency constraint. No duplicate STOP loop.
# Avoid compaction, zram recompression and OOM-score changes on every launch.
exec sudo -n /usr/lib/raptor/cortex-helper trim-background
EOF
chmod +x /usr/lib/raptor/gamemode-start

cat << 'EOF' > /usr/lib/raptor/gamemode-end
#!/bin/bash
# Restore exactly the process set that Cortex paused. The helper owns both
# lists and the Game Mode marker, avoiding duplicate or drifting resume logic.
exec sudo -n /usr/lib/raptor/cortex-helper restore-background
EOF
chmod +x /usr/lib/raptor/gamemode-end

# Enable the boot-mode unit for every user. This is what makes the GUI's
# "Apply selected mode on every boot" toggle actually do something; without
# the enable the unit exists but never runs and the mode resets on reboot.
systemctl --global enable raptor-cortex-mode.service 2>/dev/null || true

# GameMode's active configuration and hooks are written by
# raptor-gaming/install.sh to /etc/gamemode.ini. Do not create an unreferenced
# /etc/gamemode.d file that GameMode may never load.

# ── Python GUI ────────────────────────────────────────────────────────────────
cat << 'PYEOF' > /usr/bin/raptor-cortex
#!/usr/bin/env python3
"""Raptor Cortex v4.2 — Unified memory & performance management for Raptor OS"""

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib

import subprocess
import threading
import os
import sys
import time
import json
import uuid

CORTEX_CONFIG  = "/etc/raptor/cortex-suspend.conf"
HELPER         = "/usr/lib/raptor/cortex-helper"
MODE_STATE_FILE = os.path.expanduser("~/.config/raptor-cortex-mode")


def run_cortex_helper(*args, timeout=30):
    """Run the privileged helper with bounded wait and a uniform error result."""
    command = ["sudo", HELPER, *[str(arg) for arg in args]]
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(command, 124, "", str(exc))

ALL_SERVICES = [
    # Only optional indexers, thumbnail generation, and the crash reporter
    # are paused automatically. User-facing apps, audio, networking, Bluetooth,
    # package tools, and device-management services remain available.
    ("Baloo file indexer",       "baloo_file"),
    ("Baloo extractor",          "baloo_file_extractor"),
    ("Tracker miner",            "tracker-miner"),
    ("Tracker store",            "tracker-store"),
    ("Tracker 3",                "tracker3"),
    ("Thumbnail generator",     "kio_thumbnail"),
    ("Zeitgeist daemon",         "zeitgeist"),
    ("Thumbnail service",        "tumblerd"),
    ("Locate database updater",  "updatedb"),
    ("Mlocate indexer",          "mlocate"),
    ("KDE crash handler",        "drkonqi"),
]

PERFORMANCE_MODES = {
    "power_saving": (
        "Power Saving",
        "Selects PPD Power Saver; tunes PCIe ASPM and NVMe for efficiency. KDE battery slider remains authoritative.",
        "battery-low-symbolic",
        "#f5c211",
    ),
    "balanced": (
        "Balanced",
        "Selects PPD Balanced; applies moderate device power tuning without overriding CPU policy.",
        "media-playlist-shuffle-symbolic",
        "#3584e4",
    ),
    "performance": (
        "Performance",
        "Selects PPD Performance; tunes PCIe/NVMe for throughput and enables optional game-mode trimming.",
        "starred-symbolic",
        "#2ec27e",
    ),
}


def read_power_profile_mode():
    """Return the active PPD profile as a Cortex mode, or None if unavailable."""
    try:
        result = subprocess.run(
            ["powerprofilesctl", "get"], capture_output=True, text=True, timeout=3
        )
        if result.returncode != 0:
            return None
        return {
            "power-saver": "power_saving",
            "balanced": "balanced",
            "performance": "performance",
        }.get(result.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        return None


def detect_system_mode() -> str:
    """Prefer the live desktop power profile; fall back to saved Cortex state."""
    active = read_power_profile_mode()
    if active in PERFORMANCE_MODES:
        return active
    try:
        with open(MODE_STATE_FILE) as f:
            mode = f.read().strip()
            if mode in PERFORMANCE_MODES:
                return mode
    except Exception:
        pass
    return "balanced"


def persist_mode(mode: str) -> None:
    """Write the current mode to ~/.config/raptor-cortex-mode."""
    try:
        os.makedirs(os.path.dirname(MODE_STATE_FILE), exist_ok=True)
        with open(MODE_STATE_FILE, "w") as f:
            f.write(mode + "\n")
    except Exception as e:
        print(f"[cortex] Could not persist mode: {e}", file=sys.stderr)


def read_meminfo():
    info = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    key = parts[0].rstrip(":")
                    info[key] = int(parts[1]) // 1024
    except Exception:
        pass
    return info


def mem_used_mb():
    m = read_meminfo()
    total = m.get("MemTotal", 0)
    avail = m.get("MemAvailable", 0)
    return total - avail, total


def fmt_mb(mb):
    return f"{mb / 1024:.1f} GB" if mb >= 1024 else f"{mb} MB"


def get_zram_usage():
    try:
        if not os.path.exists("/sys/block/zram0"):
            return 0, 0, False
        with open("/sys/block/zram0/disksize") as f:
            total_mb = int(f.read().strip()) // (1024 * 1024)
        try:
            with open("/sys/block/zram0/mm_stat") as f:
                orig_mb = int(f.read().split()[0]) // (1024 * 1024)
        except Exception:
            orig_mb = 0
        return orig_mb, total_mb, total_mb > 0
    except Exception:
        return 0, 0, False


def get_swap_usage():
    m = read_meminfo()
    total = m.get("SwapTotal", 0)
    free  = m.get("SwapFree", 0)
    return total - free, total


def get_cpu_boost():
    try:
        with open("/sys/devices/system/cpu/cpufreq/boost") as f:
            return f.read().strip() == "1"
    except Exception:
        return None


def _read_millidegrees(path):
    """Read a sysfs temperature sensor, returning a sane Celsius integer."""
    try:
        with open(path) as f:
            raw = int(f.read().strip())
        # hwmon and thermal sysfs normally report millidegrees Celsius.
        value = raw / 1000.0 if abs(raw) > 1000 else float(raw)
        if -20.0 < value < 150.0:
            return round(value)
    except (OSError, ValueError):
        pass
    return None


def get_cpu_temp():
    """Return the CPU package temperature in °C, or None if unavailable."""
    # Thermal-zone names vary by kernel and platform. Prefer explicit CPU
    # package/core labels instead of assuming thermal_zone0 is the CPU.
    try:
        zones = sorted(os.listdir("/sys/class/thermal"))
    except OSError:
        zones = []
    preferred = ("x86_pkg_temp", "cpu-thermal", "k10temp", "cpu_thermal",
                 "soc_thermal", "acpitz")
    for wanted in preferred:
        for zone in zones:
            path = f"/sys/class/thermal/{zone}"
            try:
                with open(f"{path}/type") as f:
                    label = f.read().strip().lower()
                if wanted in label:
                    value = _read_millidegrees(f"{path}/temp")
                    if value is not None:
                        return value
            except OSError:
                continue

    # Many systems expose CPU sensors only through hwmon (k10temp,
    # coretemp, zenpower, amd_energy, etc.).
    try:
        for hw in sorted(os.listdir("/sys/class/hwmon")):
            root = f"/sys/class/hwmon/{hw}"
            try:
                with open(f"{root}/name") as f:
                    chip = f.read().strip().lower()
                if not any(token in chip for token in
                           ("k10temp", "coretemp", "zenpower", "cpu_thermal")):
                    continue
                inputs = sorted(x for x in os.listdir(root)
                                if x.startswith("temp") and x.endswith("_input"))
                candidates = []
                for item in inputs:
                    idx = item[4:-6]
                    label = ""
                    try:
                        with open(f"{root}/temp{idx}_label") as f:
                            label = f.read().strip().lower()
                    except OSError:
                        pass
                    value = _read_millidegrees(f"{root}/{item}")
                    if value is not None:
                        priority = 0 if any(x in label for x in
                                            ("package", "tctl", "tdie", "cpu")) else 1
                        candidates.append((priority, value))
                if candidates:
                    candidates.sort(key=lambda item: item[0])
                    return candidates[0][1]
            except OSError:
                continue
    except OSError:
        pass

    # Last resort: use a sane thermal-zone reading only when its type looks
    # CPU-related. Never label an arbitrary battery/GPU/skin sensor as CPU.
    for zone in zones:
        path = f"/sys/class/thermal/{zone}"
        try:
            with open(f"{path}/type") as f:
                label = f.read().strip().lower()
            if any(token in label for token in ("cpu", "package", "x86")):
                value = _read_millidegrees(f"{path}/temp")
                if value is not None:
                    return value
        except OSError:
            continue
    return None


# ── GPU performance profile ──────────────────────────────────────────────────
# The active profile is expressed as a marker file, not as configuration: an
# exact match on /etc/raptor-force-<name> tells gpu-detect.sh which of the
# profile tables to apply, and it rewrites /etc/environment.d/raptor-gpu.conf
# from it on every boot. That indirection is deliberate — it means the profile
# survives a reboot and cannot drift out of sync with the table it came from.
GPU_PROFILE_MARKERS = {
    "extreme":     "/etc/raptor-force-extreme",
    "performance": "/etc/raptor-force-performance",
    "powersave":   "/etc/raptor-force-powersave",
    "balanced":    "/etc/raptor-force-balanced",
}
GPU_PROFILES = (
    ("auto", "Auto Detect", "Picks settings based on your GPU at every boot"),
    ("balanced", "Balanced", "Normal performance, sensible power use — the daily driver"),
    ("performance", "Max Performance", "High power level, larger shader cache, threaded GL"),
    ("extreme", "Extreme", "Maximum power level, DXR raytracing hints, largest shader cache"),
    ("powersave", "Power Saving", "Low power level — for battery or heat"),
)


def get_gpu_profile():
    """Return the active GPU profile name, or 'auto' when none is forced."""
    try:
        for key, path in GPU_PROFILE_MARKERS.items():
            if os.path.exists(path):
                return key
    except Exception:
        pass
    return "auto"


def set_gpu_profile(profile):
    """Apply a GPU profile by rewriting its marker file, then re-running the
    detector so the change takes effect now rather than at the next boot.

    Mirrors the sudoers grant in /etc/sudoers.d/raptor-gpu: touch and rm are
    wildcarded to /etc/raptor-force-*, and gpu-detect.sh is called directly.
    Returns (ok, message).
    """
    if profile not in ("auto",) and profile not in GPU_PROFILE_MARKERS:
        return False, f"Unknown GPU profile '{profile}'"
    try:
        subprocess.run(["sudo", "rm", "-f", "/etc/raptor-force-extreme",
                        "/etc/raptor-force-performance",
                        "/etc/raptor-force-powersave",
                        "/etc/raptor-force-balanced"],
                       capture_output=True, timeout=20, check=True)
        if profile != "auto":
            subprocess.run(["sudo", "touch", GPU_PROFILE_MARKERS[profile]],
                           capture_output=True, timeout=20, check=True)
        # Re-run the detector so the environment file reflects the new profile
        # without waiting for a reboot.
        subprocess.run(["sudo", "/usr/lib/raptor/gpu-detect.sh"],
                       capture_output=True, timeout=120, check=True)
    except subprocess.CalledProcessError as e:
        err = (e.stderr or b"").decode(errors="replace").strip()
        return False, err.splitlines()[-1] if err else "Could not apply the profile"
    except FileNotFoundError as e:
        if "gpu-detect" in str(e):
            return False, "the raptor-gpu-profile package is not installed"
        return False, "sudo is not available"
    except Exception as e:
        return False, str(e)
    return True, "GPU profile applied"


def get_gpu_temp():
    """Return the primary GPU edge/core temperature in °C, or None."""
    # AMD and many Intel GPUs expose labelled hwmon temperature inputs.
    # Prefer edge/core over hotspot/junction to keep the displayed value
    # comparable with the normal GPU temperature shown by vendor tools.
    try:
        for hwmon in sorted(os.listdir("/sys/class/hwmon")):
            root = f"/sys/class/hwmon/{hwmon}"
            try:
                with open(f"{root}/name") as f:
                    chip = f.read().strip().lower()
                if not any(token in chip for token in ("amdgpu", "radeon", "i915", "xe")):
                    continue
                inputs = sorted(x for x in os.listdir(root)
                                if x.startswith("temp") and x.endswith("_input"))
                candidates = []
                for item in inputs:
                    idx = item[4:-6]
                    label = ""
                    try:
                        with open(f"{root}/temp{idx}_label") as f:
                            label = f.read().strip().lower()
                    except OSError:
                        pass
                    value = _read_millidegrees(f"{root}/{item}")
                    if value is not None:
                        # Prefer the conventional edge/core reading. Junction
                        # is the hotspot sensor on many AMD GPUs, even when its
                        # label also contains "GPU", so it must rank last.
                        if any(x in label for x in ("edge", "core")):
                            priority = 0
                        elif any(x in label for x in ("hotspot", "junction")):
                            priority = 3
                        elif "gpu" in label:
                            priority = 1
                        else:
                            priority = 2
                        candidates.append((priority, value))
                if candidates:
                    candidates.sort(key=lambda item: item[0])
                    return candidates[0][1]
            except OSError:
                continue
    except OSError:
        pass

    # NVIDIA supports multiple adapters; report the first GPU rather than
    # failing int() on the multi-line output.
    try:
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=2
        )
        if r.returncode == 0:
            values = [line.strip() for line in r.stdout.splitlines()
                      if line.strip().isdigit()]
            if values:
                return int(values[0])
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


# The performance mode picks the GPU profile too, so there is one decision to
# make instead of two that can contradict each other (Power Saving + a forced
# max-performance GPU burns battery for nothing).
MODE_TO_GPU_PROFILE = {
    "power_saving": "powersave",
    "balanced": "balanced",
    "performance": "performance",
}

_GPU_NAME_CACHE = None


def get_gpu_name():
    """Model name(s) of the GPU(s), e.g. 'Phoenix1' or 'GeForce RTX 4060'. Cached."""
    global _GPU_NAME_CACHE
    if _GPU_NAME_CACHE is not None:
        return _GPU_NAME_CACHE
    names = []
    try:
        out = subprocess.run(["lspci"], capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            if not re.search(r"VGA compatible|3D controller|Display controller", line):
                continue
            desc = line.split(": ", 1)[-1]
            desc = re.sub(r"\s*\(rev [0-9a-f]+\)\s*$", "", desc)
            m = re.search(r"\[([^\]]+)\]\s*$", desc)       # 'NVIDIA ... [GeForce RTX 4060]'
            if m:
                desc = m.group(1)
            else:                                           # 'Advanced Micro Devices, Inc. [AMD/ATI] Phoenix1'
                desc = re.sub(r"^.*\]\s*", "", desc)
            names.append(desc.strip())
    except Exception:
        pass
    _GPU_NAME_CACHE = " + ".join(dict.fromkeys(n for n in names if n)) or "Unknown GPU"
    return _GPU_NAME_CACHE


def get_gpu_usage(sys_root="/sys"):
    """Return (busy_percent, clock_mhz) for the first GPU that reports them; either may be None."""
    busy = clock = None
    drm = os.path.join(sys_root, "class/drm")
    try:
        cards = sorted(d for d in os.listdir(drm) if re.fullmatch(r"card\d+", d))
    except OSError:
        cards = []

    def rd(path):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return None

    for card in cards:
        dev = os.path.join(drm, card, "device")
        b = rd(os.path.join(dev, "gpu_busy_percent"))                      # AMD
        if b is not None and b.isdigit():
            busy = int(b)
        sclk = rd(os.path.join(dev, "pp_dpm_sclk"))                        # AMD: line marked with '*'
        if sclk:
            for line in sclk.splitlines():
                m = re.search(r"(\d+)\s*[Mm][Hh][Zz]\s*\*", line)
                if m:
                    clock = int(m.group(1))
        if clock is None:                                                  # Intel
            for rel in ("gt_cur_freq_mhz", "gt/gt0/rps_cur_freq_mhz"):
                v = rd(os.path.join(drm, card, rel))
                if v and v.isdigit():
                    clock = int(v)
                    break
        if busy is not None or clock is not None:
            return busy, clock
    if sys_root == "/sys":                                                 # NVIDIA
        try:
            r = subprocess.run(
                ["nvidia-smi", "--query-gpu=utilization.gpu,clocks.gr",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=2)
            if r.returncode == 0:
                a, b = [x.strip() for x in r.stdout.splitlines()[0].split(",")[:2]]
                return int(a), int(b)
        except Exception:
            pass
    return None, None


def get_gpu_summary():
    """One line for the stats panel: 'Phoenix1 · 12% · 800 MHz'."""
    busy, clock = get_gpu_usage()
    parts = [get_gpu_name()]
    if busy is not None:
        parts.append(f"{busy}%")
    if clock is not None:
        parts.append(f"{clock} MHz")
    return " · ".join(parts)


def get_fan_info():
    """Read-only fan report from hwmon (and nvidia-smi). Never writes anything.

    Returns a list of (label, text) tuples; empty list if no fan sensors exist.
    """
    fans = []
    base = "/sys/class/hwmon"
    try:
        for hw in sorted(os.listdir(base)):
            d = f"{base}/{hw}"
            try:
                with open(f"{d}/name") as f:
                    chip = f.read().strip()
            except Exception:
                chip = hw
            try:
                entries = sorted(x for x in os.listdir(d)
                                 if x.startswith("fan") and x.endswith("_input"))
            except Exception:
                continue
            for ent in entries:
                idx = ent[3:-6]
                try:
                    with open(f"{d}/{ent}") as f:
                        rpm = int(f.read().strip())
                except Exception:
                    continue
                label = None
                try:
                    with open(f"{d}/fan{idx}_label") as f:
                        label = f.read().strip()
                except Exception:
                    pass
                name = f"{chip} {label}" if label else f"{chip} fan{idx}"
                fans.append((name, f"{rpm} RPM" if rpm > 0 else "Stopped / idle"))
    except Exception:
        pass
    if not any("nvidia" in n.lower() for n, _ in fans):
        try:
            r = subprocess.run(
                ["nvidia-smi", "--query-gpu=fan.speed", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=2)
            if r.returncode == 0:
                for i, line in enumerate(r.stdout.strip().splitlines()):
                    if line.strip().isdigit():
                        fans.append((f"NVIDIA GPU {i}", f"{line.strip()} %"))
        except Exception:
            pass
    return fans


def get_cpu_freq_mhz():
    """Return current CPU frequency in MHz (core 0), or None."""
    try:
        with open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq") as f:
            return int(f.read().strip()) // 1000
    except Exception:
        return None


def format_relative_time(timestamp):
    """Convert a unix epoch timestamp into a short human-readable relative
    string — "Just now", "5 minutes ago", "2 hours ago", etc. Falls back to
    an absolute date once it's more than a week old, since "9 days ago" is
    less useful at that point than the actual date."""
    if timestamp is None:
        return "Never"
    delta = time.time() - timestamp
    if delta < 0:
        delta = 0
    if delta < 10:
        return "Just now"
    if delta < 60:
        n = int(delta)
        return f"{n} second{'s' if n != 1 else ''} ago"
    if delta < 3600:
        n = int(delta // 60)
        return f"{n} minute{'s' if n != 1 else ''} ago"
    if delta < 86400:
        n = int(delta // 3600)
        return f"{n} hour{'s' if n != 1 else ''} ago"
    if delta < 604800:
        n = int(delta // 86400)
        return f"{n} day{'s' if n != 1 else ''} ago"
    return time.strftime("%b %-d, %Y", time.localtime(timestamp))


GAMES_CONFIG_FILE = os.path.expanduser("~/.config/raptor-cortex-games.json")


_STEAM_ROOTS = (
    "~/.local/share/Steam",
    "~/.steam/steam",
    "~/.steam/root",
    "~/.var/app/com.valvesoftware.Steam/.local/share/Steam",
    "~/.var/app/com.valvesoftware.Steam/data/Steam",
)
# Steam stores tools as "apps" too; they are not games.
_STEAM_NOT_GAMES = ("proton", "steam linux runtime", "steamworks common")


def scan_steam_libraries(extra_globs=()):
    """Return installed Steam games as [{"appid": str, "name": str}], sorted by name.

    Reads every library Steam knows about (libraryfolders.vdf), including drives
    added later, the Flatpak Steam location, and common external-drive mounts.
    The old version stripped the quotes off each line before testing for
    '"appid"', so it never matched anything and always reported "No Steam games
    found"."""
    import glob
    import re
    libs = {}

    def add_lib(path):
        sa = os.path.join(path, "steamapps")
        if os.path.isdir(sa):
            libs[os.path.realpath(sa)] = True

    for root in _STEAM_ROOTS:
        root = os.path.expanduser(root)
        add_lib(root)
        try:
            with open(os.path.join(root, "steamapps", "libraryfolders.vdf"),
                      encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        for m in re.finditer(r'"path"\s+"([^"]+)"', text):
            add_lib(m.group(1).replace("\\\\", "\\"))
    for pat in ("/mnt/*/SteamLibrary", "/media/*/SteamLibrary",
                "/run/media/*/SteamLibrary", "/run/media/*/*/SteamLibrary", *extra_globs):
        for path in glob.glob(pat):
            add_lib(path)

    games = {}
    for sa in libs:
        for manifest in glob.glob(os.path.join(sa, "appmanifest_*.acf")):
            try:
                with open(manifest, encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            m_id = re.search(r'"appid"\s+"(\d+)"', text)
            m_name = re.search(r'"name"\s+"([^"]*)"', text)
            if not (m_id and m_name):
                continue
            name = m_name.group(1).strip()
            if not name or name.lower().startswith(_STEAM_NOT_GAMES):
                continue
            games[m_id.group(1)] = name
    return [{"appid": a, "name": n}
            for a, n in sorted(games.items(), key=lambda kv: kv[1].lower())]


def load_game_library():
    try:
        with open(GAMES_CONFIG_FILE) as f:
            data = json.load(f)
        return data.get("games", [])
    except Exception:
        return []


def save_game_library(games: list):
    try:
        os.makedirs(os.path.dirname(GAMES_CONFIG_FILE), exist_ok=True)
        with open(GAMES_CONFIG_FILE, "w") as f:
            json.dump({"games": games}, f, indent=2)
    except Exception as e:
        print(f"[cortex] Could not save game library: {e}", file=sys.stderr)


def _read_proc_stat(pid):
    """Return (utime_ticks, stime_ticks) for a PID, or None if it's gone."""
    try:
        # comm field (index 1) is in parens and may itself contain spaces,
        # so locate the closing ')' and split only what comes after it to
        # stay correctly aligned regardless of the process name's contents.
        with open(f"/proc/{pid}/stat") as f:
            raw = f.read()
        after = raw[raw.rfind(")") + 2:].split()
        utime = int(after[11])
        stime = int(after[12])
        return (utime, stime)
    except Exception:
        return None


def _read_proc_rss_mb(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    kb = int(line.split()[1])
                    return kb / 1024
    except Exception:
        pass
    return 0.0


def is_pid_alive(pid):
    return os.path.exists(f"/proc/{pid}")


def find_child_pids(parent_pid):
    """Direct children only — good enough for a resource-usage estimate
    without walking the full process tree."""
    children = []
    try:
        for pid_str in os.listdir("/proc"):
            if not pid_str.isdigit():
                continue
            try:
                with open(f"/proc/{pid_str}/stat") as f:
                    raw = f.read()
                after = raw[raw.rfind(")") + 2:].split()
                ppid = int(after[1])
                if ppid == parent_pid:
                    children.append(int(pid_str))
            except Exception:
                continue
    except Exception:
        pass
    return children


class ProcessMonitor:
    """Tracks CPU% and RAM for a PID (plus its direct children) across ticks.
    CPU% requires two time-separated samples — this holds the previous
    sample so each tick only needs one /proc read per process."""

    def __init__(self, pid):
        self.pid = pid
        self._prev_ticks = None
        self._prev_time = None
        self._clk_tck = os.sysconf("SC_CLK_TCK")

    def alive(self):
        return is_pid_alive(self.pid)

    def sample(self):
        """Returns (cpu_percent, rss_mb) summed across the tracked PID and
        its direct children. Returns (0.0, 0.0) if the process is gone."""
        if not self.alive():
            return (0.0, 0.0)

        pids = [self.pid] + find_child_pids(self.pid)
        total_ticks = 0
        total_rss = 0.0
        now = time.time()

        for pid in pids:
            stat = _read_proc_stat(pid)
            if stat is not None:
                total_ticks += stat[0] + stat[1]
            total_rss += _read_proc_rss_mb(pid)

        cpu_pct = 0.0
        if self._prev_ticks is not None and self._prev_time is not None:
            elapsed = now - self._prev_time
            if elapsed > 0:
                delta_ticks = total_ticks - self._prev_ticks
                cpu_pct = 100.0 * (delta_ticks / self._clk_tck) / elapsed

        self._prev_ticks = total_ticks
        self._prev_time = now
        return (max(0.0, cpu_pct), total_rss)


def find_new_process_after_launch(exclude_pids: set, hint_exclude_names=("steam", "steamwebhelper", "reaper"),
                                   timeout_sec=20, poll_interval=1.5):
    """Best-effort detection of a newly-launched game process, for launchers
    (Steam) that don't hand back a direct PID. Polls /proc for new PIDs that
    weren't running before launch and don't look like launcher infrastructure,
    picking the one using the most RAM as the likely game process — actual
    games are almost always the largest new process, launcher helpers are not.
    This is inherently heuristic; it can fail to find the right process,
    especially for games that spawn many worker processes."""
    deadline = time.time() + timeout_sec
    best_pid = None
    best_rss = 0.0

    while time.time() < deadline:
        try:
            current_pids = {int(p) for p in os.listdir("/proc") if p.isdigit()}
        except Exception:
            current_pids = set()
        new_pids = current_pids - exclude_pids

        for pid in new_pids:
            try:
                with open(f"/proc/{pid}/comm") as f:
                    comm = f.read().strip().lower()
            except Exception:
                continue
            if any(h in comm for h in hint_exclude_names):
                continue
            rss = _read_proc_rss_mb(pid)
            if rss > best_rss:
                best_rss = rss
                best_pid = pid

        # Require a minimum RSS before trusting the guess — avoids locking
        # onto a tiny short-lived helper process that happens to appear first.
        if best_pid is not None and best_rss > 150:
            return best_pid

        time.sleep(poll_interval)

    return best_pid  # may be None, or a low-confidence guess


def load_persistent_settings():
    """Load persistent Cortex settings from ~/.config/raptor-cortex-settings.json."""
    defaults = {
        "auto_apply_mode_on_boot": True,
        "gpu_follows_mode": True,
        "auto_restore_after_game": True,
        "sched_cleanup_enabled": False,
        "sched_cleanup_interval_min": 30,
        "last_optimize_timestamp": None,
    }
    settings_file = os.path.expanduser("~/.config/raptor-cortex-settings.json")
    try:
        with open(settings_file) as f:
            loaded = json.load(f)
        defaults.update(loaded)
    except Exception:
        pass
    return defaults


def save_persistent_settings(settings: dict):
    """Save persistent Cortex settings."""
    settings_file = os.path.expanduser("~/.config/raptor-cortex-settings.json")
    try:
        os.makedirs(os.path.dirname(settings_file), exist_ok=True)
        with open(settings_file, "w") as f:
            json.dump(settings, f, indent=2)
    except Exception as e:
        print(f"[cortex] Could not save settings: {e}", file=sys.stderr)


def load_cortex_config():
    patterns = set()
    try:
        with open(CORTEX_CONFIG) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    patterns.add(line)
    except Exception:
        pass
    # First-run defaults are restricted to optional indexers and thumbnailers.
    # Existing config entries are filtered by the helper's safe process allowlist.
    if not patterns:
        defaults = {
            "baloo_file",
            "baloo_file_extractor",
            "tracker-miner",
            "tracker-store",
            "tracker3",
            "kio_thumbnail",
            "zeitgeist",
            "tumblerd",
            "updatedb",
            "mlocate",
        }
        patterns.update(defaults)
        # Persist the defaults so they survive reboots
        threading.Thread(target=save_cortex_config, args=(patterns,), daemon=True).start()
    return patterns


def save_cortex_config(patterns):
    try:
        lines = [
            "# Raptor Cortex — services to suspend during gaming\n",
            "# This file is managed by the Raptor Cortex GUI.\n",
        ]
        for _, pattern in ALL_SERVICES:
            if pattern in patterns:
                lines.append(pattern + "\n")
        with open(CORTEX_CONFIG, "w") as f:
            f.writelines(lines)
    except Exception as e:
        print(f"[cortex] Could not save config: {e}", file=sys.stderr)


class RaptorCortexApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.cerberus9dev.RaptorCortex")
        self.connect("activate", self.on_activate)

    def on_activate(self, app):
        self.win = RaptorCortexWindow(application=app)
        self.win.present()


class RaptorCortexWindow(Adw.ApplicationWindow):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.set_title("Raptor Cortex")
        self.set_default_size(700, 940)
        self._running = False
        self._suspended_now = []
        self._cortex_patterns = load_cortex_config()
        # Read the persisted mode and persistent settings
        self._current_mode = detect_system_mode()
        self._settings = load_persistent_settings()
        self._sched_cleanup_id = None   # GLib timer handle
        self._mode_btns = {}
        self._toast_overlay = None
        self._build_ui()
        GLib.timeout_add_seconds(5, self._refresh_stats)
        # First reading happens after the window is on screen (on a worker thread).
        GLib.idle_add(lambda: (self._refresh_stats(), False)[1])

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)
        root.append(Adw.HeaderBar())

        # Toast overlay wraps the scrollable content
        self._toast_overlay = Adw.ToastOverlay()
        self._toast_overlay.set_vexpand(True)
        root.append(self._toast_overlay)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)
        self._toast_overlay.set_child(scroll)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        content.set_margin_top(20)
        content.set_margin_bottom(20)
        content.set_margin_start(20)
        content.set_margin_end(20)
        scroll.set_child(content)

        self.mode_banner = Adw.Banner()
        self.mode_banner.set_revealed(True)
        self._update_mode_banner()
        content.append(self.mode_banner)

        stats_group = Adw.PreferencesGroup(title="System Memory")
        content.append(stats_group)

        ram_row = Adw.ActionRow(title="RAM Usage")
        self.ram_bar = Gtk.LevelBar()
        self.ram_bar.set_min_value(0)
        self.ram_bar.set_max_value(1)
        self.ram_bar.set_size_request(200, -1)
        self.ram_bar.set_valign(Gtk.Align.CENTER)
        self.ram_label = Gtk.Label(label="…")
        self.ram_label.add_css_class("dim-label")
        ram_row.add_suffix(self.ram_label)
        ram_row.add_suffix(self.ram_bar)
        stats_group.add(ram_row)

        self.swap_row = Adw.ActionRow(title="Swap / zram")
        self.swap_label = Gtk.Label(label="…")
        self.swap_label.add_css_class("dim-label")
        self.swap_row.add_suffix(self.swap_label)
        stats_group.add(self.swap_row)

        self.zram_row = Adw.ActionRow(title="zram compression")
        self.zram_label = Gtk.Label(label="…")
        self.zram_label.add_css_class("dim-label")
        self.zram_row.add_suffix(self.zram_label)
        stats_group.add(self.zram_row)

        self.boost_row = Adw.ActionRow(title="CPU Boost")
        self.boost_label = Gtk.Label(label="…")
        self.boost_label.add_css_class("dim-label")
        self.boost_row.add_suffix(self.boost_label)
        stats_group.add(self.boost_row)

        self.cpu_temp_row = Adw.ActionRow(title="CPU Temperature")
        self.cpu_temp_label = Gtk.Label(label="…")
        self.cpu_temp_label.add_css_class("dim-label")
        self.cpu_temp_row.add_suffix(self.cpu_temp_label)
        stats_group.add(self.cpu_temp_row)

        self.gpu_temp_row = Adw.ActionRow(title="GPU Temperature")
        self.gpu_temp_label = Gtk.Label(label="…")
        self.gpu_temp_label.add_css_class("dim-label")
        self.gpu_temp_row.add_suffix(self.gpu_temp_label)
        stats_group.add(self.gpu_temp_row)

        self.gpu_info_row = Adw.ActionRow(title="GPU")
        self.gpu_info_label = Gtk.Label(label="…")
        self.gpu_info_label.add_css_class("dim-label")
        self.gpu_info_label.set_wrap(True)
        self.gpu_info_label.set_justify(Gtk.Justification.RIGHT)
        self.gpu_info_row.add_suffix(self.gpu_info_label)
        stats_group.add(self.gpu_info_row)

        # Read-only fan information — Cortex never writes fan speed or curves.
        self.fan_row = Adw.ActionRow(title="Fans")
        self.fan_row.set_subtitle("Read-only — fan control is left to the kernel and firmware")
        self.fan_label = Gtk.Label(label="…")
        self.fan_label.add_css_class("dim-label")
        self.fan_label.set_wrap(True)
        self.fan_label.set_justify(Gtk.Justification.RIGHT)
        self.fan_row.add_suffix(self.fan_label)
        stats_group.add(self.fan_row)

        self.cpu_freq_row = Adw.ActionRow(title="CPU Frequency")
        self.cpu_freq_label = Gtk.Label(label="…")
        self.cpu_freq_label.add_css_class("dim-label")
        self.cpu_freq_row.add_suffix(self.cpu_freq_label)
        stats_group.add(self.cpu_freq_row)

        self.last_optimize_row = Adw.ActionRow(title="Last Optimization")
        self.last_optimize_label = Gtk.Label(label="…")
        self.last_optimize_label.add_css_class("dim-label")
        self.last_optimize_row.add_suffix(self.last_optimize_label)
        stats_group.add(self.last_optimize_row)

        mode_group = Adw.PreferencesGroup(title="Performance Mode")
        mode_group.set_description(
            "Selects the matching system power profile through power-profiles-daemon, then tunes "
            "independent device power settings. KDE retains control of CPU policy and the battery slider.")
        content.append(mode_group)

        ICON_FALLBACKS = {
            "power_saving": "battery-low-symbolic",
            "balanced":     "media-playlist-shuffle-symbolic",
            "performance":  "starred-symbolic",
        }

        for key, (label, desc, _, color) in PERFORMANCE_MODES.items():
            icon = Gtk.Image.new_from_icon_name(ICON_FALLBACKS[key])
            icon.set_pixel_size(20)
            icon.set_valign(Gtk.Align.CENTER)
            icon.set_margin_end(4)

            check = Gtk.Image.new_from_icon_name("object-select-symbolic")
            check.set_pixel_size(16)
            check.set_valign(Gtk.Align.CENTER)

            row = Adw.ActionRow(title=label)
            row.set_subtitle(desc)
            row.set_activatable(True)
            row.connect("activated", self._on_mode_switch, key)
            row.add_prefix(icon)
            row.add_suffix(check)
            mode_group.add(row)

            self._mode_btns[key] = (row, icon, check)

        self._refresh_mode_buttons()

        # ── Graphics ────────────────────────────────────────────────────────────
        # GPU performance profile. This used to be a separate app called Raptor
        # GPU Profiler; it lives here now alongside system power modes, avoiding
        # two windows and two launchers for related performance controls.
        gfx_group = Adw.PreferencesGroup(
            title="Graphics",
            description="Tuning for your GPU. Applies immediately and survives reboot. "
                        "By default it follows the performance mode above.")

        if not os.path.exists("/usr/lib/raptor/gpu-detect.sh"):
            # gpu-detect.sh ships in the raptor-gpu-profile package. If that
            # package is not installed there is nothing to switch, so say so
            # rather than offering buttons that quietly do nothing.
            row = Adw.ActionRow(title="GPU profiles unavailable")
            row.set_subtitle(
                "Install the raptor-gpu-profile package to select a GPU "
                "performance profile.")
            gfx_group.add(row)
        else:
            self.gfx_follow_row = self._switch_row(
                "Match GPU to performance mode",
                "Power Saving, Balanced and Performance above also set the GPU profile, "
                "so you only choose once. Pick a profile below to override.",
                self._settings.get("gpu_follows_mode", True))
            self.gfx_follow_row.connect("notify::active", self._on_gpu_follow_toggle)
            gfx_group.add(self.gfx_follow_row)
            self._gfx_rows = {}
            for key, title, subtitle in GPU_PROFILES:
                check = Gtk.CheckButton(valign=Gtk.Align.CENTER)
                row = Adw.ActionRow(title=title, subtitle=subtitle)
                row.set_activatable(True)
                row.add_prefix(Gtk.Image.new_from_icon_name(
                    "preferences-desktop-display-symbolic"))
                row.add_suffix(check)
                row.connect("activated", self._on_gpu_profile, key)
                gfx_group.add(row)
                self._gfx_rows[key] = (row, check)
            self._refresh_gpu_profile()

        content.append(gfx_group)

        # ── Game Library ─────────────────────────────────────────────────────────
        # The primary, front-and-centre feature: add a game once, then launch
        # it directly from Cortex. Launching automatically applies the game's
        # boost mode and tracks its CPU/RAM live while it runs — no manual
        # mode-switching or optimize-clicking needed for games in the library.
        game_group = Adw.PreferencesGroup(title="Game Library")
        game_group.set_description(
            "Launch a game from here to boost automatically and monitor it live.")
        content.append(game_group)
        self._game_group = game_group
        self._game_rows = {}       # game id -> (Adw.ActionRow, monitor_labels dict)
        self._active_monitor = None  # ProcessMonitor for the currently-running tracked game
        self._active_game_id = None
        self._monitor_timer_id = None
        self._pre_launch_mode = None  # mode to restore to when the game exits

        self._games = load_game_library()
        self._rebuild_game_rows()

        add_game_row = Adw.ActionRow(title="Add a Game")
        add_game_row.set_subtitle("Point at a game executable, or launch by Steam App ID")
        add_game_row.set_activatable(True)
        add_icon = Gtk.Image.new_from_icon_name("list-add-symbolic")
        add_icon.set_pixel_size(18)
        add_game_row.add_prefix(add_icon)
        add_game_row.connect("activated", self._on_add_game_clicked)
        game_group.add(add_game_row)

        # Steam auto-detection
        scan_row = Adw.ActionRow(title="Scan for Steam Games")
        scan_row.set_subtitle("Auto-detect installed Steam games and add them to the library")
        scan_row.set_activatable(True)
        scan_icon = Gtk.Image.new_from_icon_name("view-refresh-symbolic")
        scan_icon.set_pixel_size(18)
        scan_row.add_prefix(scan_icon)
        scan_row.connect("activated", self._on_scan_steam_games)
        game_group.add(scan_row)

        # ── Simplified optimization ─────────────────────────────────────────────
        # One preset button for the common case, with the previous 6 raw
        # toggles moved into a collapsed "Advanced" row for anyone who wants
        # fine control — most people just want "make it faster" without
        # reading through 6 technical checkboxes first.
        opts_group = Adw.PreferencesGroup(title="Optimize Memory")
        opts_group.set_description(
            "Quick Optimize covers the common case. Advanced options are available below if you want finer control.")
        content.append(opts_group)

        # Quick Optimize — pressure-aware and deliberately non-disruptive
        quick_row = Adw.ActionRow(title="One-Click Boost")
        quick_row.set_subtitle(
            "Apply Performance mode, tune the GPU when supported, pause optional indexers, "
            "and reclaim memory only under real pressure. Use Restore Desktop to undo.")
        quick_row.set_activatable(True)
        quick_icon = Gtk.Image.new_from_icon_name("system-run-symbolic")
        quick_icon.set_pixel_size(18)
        quick_row.add_prefix(quick_icon)
        quick_row.connect("activated", self._on_pregame_boost)
        opts_group.add(quick_row)

        advanced_expander = Adw.ExpanderRow(title="Advanced Options")
        advanced_expander.set_subtitle("Choose exactly what runs — off by default, Quick Optimize above covers most cases")
        opts_group.add(advanced_expander)

        self.opt_caches  = self._switch_row("Pressure-aware app memory reclaim",
                                             "Requests up to 256 MiB only when available RAM is low; keeps useful file/game caches",
                                             True)
        advanced_expander.add_row(self.opt_caches)
        self.opt_compact = self._switch_row("Memory compaction",                 "Manual only; can briefly use CPU and is disabled in Quick Optimize", False)
        advanced_expander.add_row(self.opt_compact)
        self.opt_zram    = self._switch_row("zram recompress",                   "Recompress up to 128 idle pages when supported; no disk writeback", False)
        advanced_expander.add_row(self.opt_zram)
        self.opt_swap    = self._switch_row("Extra pressure reclaim",               "Request a larger reclaim only when available RAM is low",
                                             False)
        advanced_expander.add_row(self.opt_swap)
        self.opt_oom     = self._switch_row("Adjust OOM scores",                 "Optional process-priority policy; disabled by default", False)
        advanced_expander.add_row(self.opt_oom)
        self.opt_deep    = self._switch_row("Deep Clean (slow)",                 "Advanced manual operation; can interrupt responsiveness", False)
        advanced_expander.add_row(self.opt_deep)

        cortex_group = Adw.PreferencesGroup(title="Raptor Cortex — Game Mode")
        cortex_group.set_description(
            "Selected services are suspended when any game launches and resumed when it exits.")
        content.append(cortex_group)

        self._service_switches = {}
        for name, pattern in ALL_SERVICES:
            row = Adw.SwitchRow()
            row.set_title(name)
            row.set_subtitle(f"pgrep: {pattern}")
            row.set_active(pattern in self._cortex_patterns)
            row.connect("notify::active", self._on_cortex_toggle, pattern)
            cortex_group.add(row)
            self._service_switches[pattern] = row

        self.result_group = Adw.PreferencesGroup(title="Last Optimization")
        self.result_group.set_visible(False)
        content.append(self.result_group)

        self.result_row = Adw.ActionRow()
        self.result_row.set_title("Freed")
        self.result_icon = Gtk.Image.new_from_icon_name("emblem-ok-symbolic")
        self.result_icon.add_css_class("success")
        self.result_row.add_prefix(self.result_icon)
        self.result_group.add(self.result_row)

        self.sus_group = Adw.PreferencesGroup(title="Currently Suspended")
        self.sus_group.set_visible(False)
        content.append(self.sus_group)

        self.sus_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        self.sus_group.add(self.sus_box)

        # ── Quick Actions ──────────────────────────────────────────────────────
        quick_group = Adw.PreferencesGroup(title="Quick Actions")
        quick_group.set_description(
            "One-click presets for common scenarios. Effects are immediate.")
        content.append(quick_group)

        boost_row = Adw.ActionRow(title="Pre-Game Boost")
        boost_row.set_subtitle(
            "Switch to Performance mode and pause optional indexers; reclaim memory only if RAM pressure is high")
        boost_row.set_activatable(True)
        boost_row.connect("activated", self._on_pregame_boost)
        boost_icon = Gtk.Image.new_from_icon_name("media-playback-start-symbolic")
        boost_icon.set_pixel_size(18)
        boost_row.add_prefix(boost_icon)
        quick_group.add(boost_row)

        restore_row = Adw.ActionRow(title="Restore Desktop")
        restore_row.set_subtitle(
            "Switch back to Balanced, resume all suspended services")
        restore_row.set_activatable(True)
        restore_row.connect("activated", self._on_restore_desktop)
        rest_icon = Gtk.Image.new_from_icon_name("go-home-symbolic")
        rest_icon.set_pixel_size(18)
        restore_row.add_prefix(rest_icon)
        quick_group.add(restore_row)

        shader_row = Adw.ActionRow(title="Clear Shader Cache")
        shader_row.set_subtitle(
            "Delete Mesa, DXVK, and Steam shader caches — fixes visual glitches, "
            "frees disk space (shaders rebuild on next game launch)")
        shader_row.set_activatable(True)
        shader_row.connect("activated", self._on_clear_shaders)
        shader_icon = Gtk.Image.new_from_icon_name("edit-clear-all-symbolic")
        shader_icon.set_pixel_size(18)
        shader_row.add_prefix(shader_icon)
        quick_group.add(shader_row)

        # ── Persistent Settings ────────────────────────────────────────────────
        persist_group = Adw.PreferencesGroup(title="Persistent Settings")
        persist_group.set_description(
            "These settings survive reboots and are applied automatically.")
        content.append(persist_group)

        self.boot_mode_row = Adw.SwitchRow()
        self.boot_mode_row.set_title("Apply selected mode on every boot")
        self.boot_mode_row.set_subtitle(
            "Restores the Performance/Balanced/Power Saving mode after each reboot")
        self.boot_mode_row.set_active(self._settings.get("auto_apply_mode_on_boot", True))
        self.boot_mode_row.connect("notify::active", self._on_setting_toggle, "auto_apply_mode_on_boot")
        persist_group.add(self.boot_mode_row)

        self.auto_restore_row = Adw.SwitchRow()
        self.auto_restore_row.set_title("Auto-restore mode when a game closes")
        self.auto_restore_row.set_subtitle(
            "Applies to games launched from your Game Library — switches back to your previous mode when the game exits")
        self.auto_restore_row.set_active(self._settings.get("auto_restore_after_game", True))
        self.auto_restore_row.connect("notify::active", self._on_setting_toggle, "auto_restore_after_game")
        persist_group.add(self.auto_restore_row)

        # ── Scheduled Cleanup ─────────────────────────────────────────────────
        sched_group = Adw.PreferencesGroup(title="Scheduled Memory Cleanup")
        sched_group.set_description(
            "Automatically run memory optimization in the background on a timer. "
            "Useful for long gaming sessions where browser memory grows over time.")
        content.append(sched_group)

        self.sched_enable_row = Adw.SwitchRow()
        self.sched_enable_row.set_title("Enable scheduled cleanup")
        self.sched_enable_row.set_subtitle("Runs the enabled optimization options above on a timer")
        self.sched_enable_row.set_active(self._settings.get("sched_cleanup_enabled", False))
        self.sched_enable_row.connect("notify::active", self._on_sched_toggle)
        sched_group.add(self.sched_enable_row)

        self.sched_interval_row = Adw.SpinRow.new_with_range(5, 120, 5)
        self.sched_interval_row.set_title("Cleanup interval (minutes)")
        self.sched_interval_row.set_subtitle("How often to run the automatic cleanup")
        self.sched_interval_row.set_value(self._settings.get("sched_cleanup_interval_min", 30))
        self.sched_interval_row.set_sensitive(self._settings.get("sched_cleanup_enabled", False))
        self.sched_interval_row.connect("changed", self._on_sched_interval_changed)
        sched_group.add(self.sched_interval_row)

        self.sched_status_row = Adw.ActionRow(title="Next cleanup")
        self.sched_status_label = Gtk.Label(label="Disabled")
        self.sched_status_label.add_css_class("dim-label")
        self.sched_status_row.add_suffix(self.sched_status_label)
        sched_group.add(self.sched_status_row)

        # Start timer if it was enabled last session
        if self._settings.get("sched_cleanup_enabled", False):
            self._start_sched_cleanup()

        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btn_box.set_halign(Gtk.Align.CENTER)
        content.append(btn_box)

        self.run_btn = Gtk.Button(label="Quick Optimize")
        self.run_btn.add_css_class("suggested-action")
        self.run_btn.add_css_class("pill")
        self.run_btn.connect("clicked", self.on_optimize)
        btn_box.append(self.run_btn)

        self.resume_btn = Gtk.Button(label="Resume All Services")
        self.resume_btn.add_css_class("pill")
        self.resume_btn.set_sensitive(False)
        self.resume_btn.connect("clicked", self.on_resume)
        btn_box.append(self.resume_btn)

        self.spinner = Gtk.Spinner()
        btn_box.append(self.spinner)

    # ── Quick Action handlers ──────────────────────────────────────────────────

    def _on_pregame_boost(self, row):
        """One-button boost: apply the profile, then safe memory/process tuning."""
        if self._running:
            self._toast_error("Cortex is already running an optimization")
            return
        self._running = True
        self.run_btn.set_sensitive(False)
        self.spinner.start()
        before, total = mem_used_mb()
        threading.Thread(
            target=self._do_one_click_boost, args=(before, total), daemon=True
        ).start()

    def _do_one_click_boost(self, before, total):
        # Run in strict order: never claim success before each requested stage
        # has completed. CPU policy stays with power-profiles-daemon.
        mode = run_cortex_helper("set-mode", "performance")
        if mode.returncode != 0:
            err = (mode.stderr or mode.stdout or "Power profile failed").strip()
            GLib.idle_add(self._one_click_boost_done, False, before, total, 0,
                          f"Performance mode failed: {err[:220]}")
            return

        # Reclaim only the current user's cgroup, and only when MemAvailable
        # is genuinely low. Useful file/game caches and system services remain.
        memory = run_cortex_helper("1", "0", "0", "0", "0", "0", "0", "0")
        if memory.returncode != 0:
            err = (memory.stderr or memory.stdout or "Memory reclaim failed").strip()
            run_cortex_helper("set-mode", "balanced")
            GLib.idle_add(self._one_click_boost_done, False, before, total, 0,
                          f"Memory optimization failed; reverted to Balanced: {err[:160]}")
            return

        game = run_cortex_helper("trim-background")
        if game.returncode != 0:
            err = (game.stderr or game.stdout or "Game Mode setup failed").strip()
            run_cortex_helper("restore-background")
            run_cortex_helper("set-mode", "balanced")
            GLib.idle_add(self._one_click_boost_done, False, before, total, 0,
                          f"Game Mode failed; reverted to Balanced: {err[:160]}")
            return

        gpu_note = ""
        if (self._settings.get("gpu_follows_mode", True)
                and os.path.exists("/usr/lib/raptor/gpu-detect.sh")):
            profile = MODE_TO_GPU_PROFILE.get("performance")
            if profile and get_gpu_profile() != profile:
                gpu_ok, _ = set_gpu_profile(profile)
                gpu_note = " GPU profile updated." if gpu_ok else " GPU profile unchanged."

        after, _ = mem_used_mb()
        freed = max(0, before - after)
        GLib.idle_add(self._one_click_boost_done, True, before, total, freed,
                      "Performance mode and Game Mode are active. Optional indexers paused; "
                      "memory reclaim was applied only if RAM pressure was high." + gpu_note)

    def _one_click_boost_done(self, ok, before, total, freed, message):
        self._running = False
        self.run_btn.set_sensitive(True)
        self.spinner.stop()
        if ok:
            self._settings["last_optimize_timestamp"] = time.time()
            threading.Thread(
                target=save_persistent_settings, args=(self._settings,), daemon=True
            ).start()
            self._current_mode = "performance"
            persist_mode("performance")
        else:
            # Failure paths may have reverted PPD to Balanced. Query the daemon
            # off the GTK thread; the callback updates the visible mode safely.
            self._profile_sync_busy = True
            threading.Thread(
                target=self._sync_external_power_mode, daemon=True
            ).start()
        self._refresh_mode_buttons()
        self._update_mode_banner()
        self._refresh_stats()
        self.result_group.set_visible(True)
        self.result_row.set_title(f"Memory change: {fmt_mb(freed)}")
        self.result_row.set_subtitle(
            f"Before: {fmt_mb(before)} / {fmt_mb(total)}; after: {fmt_mb(mem_used_mb()[0])} / {fmt_mb(total)}")
        if ok:
            self._toast_ok(message)
            self.resume_btn.set_sensitive(True)
        else:
            self._toast_error(message)
        return False

    def _on_restore_desktop(self, row):
        """Switch to Balanced + resume all suspended services."""
        self._on_mode_switch(None, "balanced")
        threading.Thread(target=self._resume_services, daemon=True).start()

    def _resume_services(self):
        self._run_restore_background()
        GLib.idle_add(self.resume_btn.set_sensitive, False)

    def _run_restore_background(self):
        """Resume suspended background services, reporting any failure.

        Both "Restore Desktop" and "Resume All Services" funnel through here
        so a failed restore can never be reported to the user as a success.
        """
        proc = subprocess.run(["sudo", HELPER, "restore-background"],
                              capture_output=True)
        if proc.returncode != 0:
            err = (proc.stderr or b"").decode(errors="replace").strip()
            GLib.idle_add(self._toast_error,
                          "Restore failed — services may stay suspended")
            sys.stderr.write(f"cortex: restore-background failed "
                             f"(rc={proc.returncode}): {err}\n")
        else:
            GLib.idle_add(self._toast_ok, "All services resumed")

    def _toast_error(self, message):
        toast = Adw.Toast.new(message)
        toast.set_timeout(5)
        self._toast_overlay.add_toast(toast)

    def _toast_ok(self, message):
        toast = Adw.Toast.new(message)
        toast.set_timeout(3)
        self._toast_overlay.add_toast(toast)

    def _on_clear_shaders(self, row):
        """Clear Mesa, DXVK, and Steam shader caches."""
        import shutil, glob
        home = os.path.expanduser("~")
        targets = [
            f"{home}/.cache/mesa_shader_cache",
            f"{home}/.cache/mesa_shader_cache_db",
            f"{home}/.cache/radv_cache",
            f"{home}/.cache/amdvlk",
            f"{home}/.local/share/vulkan/implicit_layer.d",
        ]
        # DXVK state caches
        targets += glob.glob(f"{home}/.local/share/Steam/steamapps/shadercache/**/*",
                             recursive=True)
        freed_mb = 0
        removed = 0
        for t in targets:
            try:
                if os.path.isdir(t):
                    size = sum(
                        os.path.getsize(os.path.join(dp, f))
                        for dp, _, fns in os.walk(t) for f in fns
                    ) // (1024 * 1024)
                    shutil.rmtree(t, ignore_errors=True)
                    freed_mb += size
                    removed += 1
                elif os.path.isfile(t):
                    freed_mb += os.path.getsize(t) // (1024 * 1024)
                    os.remove(t)
                    removed += 1
            except Exception:
                pass
        msg = f"Shader cache cleared — {freed_mb} MB freed ({removed} directories removed)"
        GLib.idle_add(self._show_toast, msg)

    def _show_toast(self, msg):
        toast = Adw.Toast.new(msg)
        toast.set_timeout(4)
        self._toast_overlay.add_toast(toast)

    # ── Persistent Settings handlers ───────────────────────────────────────────

    def _on_setting_toggle(self, row, _param, key):
        self._settings[key] = row.get_active()
        threading.Thread(
            target=save_persistent_settings, args=(self._settings,), daemon=True
        ).start()

    # ── Scheduled Cleanup handlers ─────────────────────────────────────────────

    def _on_sched_toggle(self, row, _param):
        enabled = row.get_active()
        self._settings["sched_cleanup_enabled"] = enabled
        self.sched_interval_row.set_sensitive(enabled)
        threading.Thread(
            target=save_persistent_settings, args=(self._settings,), daemon=True
        ).start()
        if enabled:
            self._start_sched_cleanup()
        else:
            self._stop_sched_cleanup()
            GLib.idle_add(self.sched_status_label.set_text, "Disabled")

    def _on_sched_interval_changed(self, row):
        interval = int(row.get_value())
        self._settings["sched_cleanup_interval_min"] = interval
        threading.Thread(
            target=save_persistent_settings, args=(self._settings,), daemon=True
        ).start()
        if self._settings.get("sched_cleanup_enabled", False):
            self._stop_sched_cleanup()
            self._start_sched_cleanup()

    def _start_sched_cleanup(self):
        self._stop_sched_cleanup()
        interval_min = self._settings.get("sched_cleanup_interval_min", 30)
        interval_ms  = interval_min * 60 * 1000
        self._sched_cleanup_id = GLib.timeout_add(interval_ms, self._run_sched_cleanup)
        GLib.idle_add(
            self.sched_status_label.set_text,
            f"Every {interval_min} min — next in {interval_min} min"
        )

    def _stop_sched_cleanup(self):
        if self._sched_cleanup_id is not None:
            GLib.source_remove(self._sched_cleanup_id)
            self._sched_cleanup_id = None

    def _run_sched_cleanup(self):
        """Called by GLib timer — run the enabled optimize options silently."""
        opts = {
            "caches":  self.opt_caches.get_active(),
            "compact": self.opt_compact.get_active(),
            "zram":    self.opt_zram.get_active(),
            "swap":    False,   # never auto-swap-flush
            "oom":     self.opt_oom.get_active(),
            "deep":    False,   # never auto deep-clean
            "thp":     False,
            "cpu":     False,
        }
        before, total = mem_used_mb()
        threading.Thread(
            target=self._do_optimize, args=(opts, before, total), daemon=True
        ).start()
        interval_min = self._settings.get("sched_cleanup_interval_min", 30)
        GLib.idle_add(
            self.sched_status_label.set_text,
            f"Every {interval_min} min — running now…"
        )
        # Re-schedule (return True keeps the timer alive)
        return True

    # ── Game Library ──────────────────────────────────────────────────────────

    def _rebuild_game_rows(self):
        """Clear and redraw every row in the Game Library group from
        self._games. Called after add/edit/remove."""
        for game_id, (row, _labels) in list(self._game_rows.items()):
            self._game_group.remove(row)
        self._game_rows.clear()

        for game in self._games:
            row = self._build_game_row(game)
            # Insert before the "Add a Game" row, which is always last —
            # PreferencesGroup doesn't expose insert-at-index, so remove and
            # re-add "Add a Game" isn't needed since new rows always append
            # above it as long as we build games first at startup. For rows
            # added after the fact, the group naturally appends to the end;
            # this is a minor cosmetic ordering quirk, not a functional one.
            self._game_group.add(row)
            self._game_rows[game["id"]] = (row, {})

    def _build_game_row(self, game: dict) -> Adw.ActionRow:
        row = Adw.ActionRow(title=game["name"])
        row.set_subtitle("Not running")

        icon = Gtk.Image.new_from_icon_name("input-gaming-symbolic")
        icon.set_pixel_size(20)
        row.add_prefix(icon)

        play_btn = Gtk.Button()
        play_btn.set_child(Gtk.Image.new_from_icon_name("media-playback-start-symbolic"))
        play_btn.add_css_class("flat")
        play_btn.set_valign(Gtk.Align.CENTER)
        play_btn.set_tooltip_text(f"Launch {game['name']}")
        play_btn.connect("clicked", lambda _b, g=game: self._on_play_button_clicked(g))
        row.add_suffix(play_btn)
        row._raptor_play_btn = play_btn  # stash for later state updates

        menu_btn = Gtk.MenuButton()
        menu_btn.set_icon_name("view-more-symbolic")
        menu_btn.add_css_class("flat")
        menu_btn.set_valign(Gtk.Align.CENTER)
        popover = Gtk.Popover()
        menu_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        menu_box.set_margin_top(6)
        menu_box.set_margin_bottom(6)
        menu_box.set_margin_start(6)
        menu_box.set_margin_end(6)
        edit_btn = Gtk.Button(label="Edit")
        edit_btn.add_css_class("flat")
        edit_btn.connect("clicked", lambda _b, g=game, p=popover: (p.popdown(), self._on_edit_game_clicked(g)))
        remove_btn = Gtk.Button(label="Remove")
        remove_btn.add_css_class("flat")
        remove_btn.add_css_class("destructive-action")
        remove_btn.connect("clicked", lambda _b, g=game, p=popover: (p.popdown(), self._on_remove_game(g)))
        menu_box.append(edit_btn)
        menu_box.append(remove_btn)
        popover.set_child(menu_box)
        menu_btn.set_popover(popover)
        row.add_suffix(menu_btn)

        return row

    def _on_play_button_clicked(self, game):
        if self._active_game_id == game["id"]:
            self._on_stop_monitoring_only(game)
        else:
            self._on_launch_game(game)

    def _on_add_game_clicked(self, _row):
        dialog = GameEditDialog(self, game=None, on_save=self._on_game_saved)
        dialog.present()

    def _on_edit_game_clicked(self, game):
        dialog = GameEditDialog(self, game=game, on_save=self._on_game_saved)
        dialog.present()

    def _on_game_saved(self, game: dict):
        existing_ids = {g["id"] for g in self._games}
        if game["id"] in existing_ids:
            self._games = [game if g["id"] == game["id"] else g for g in self._games]
        else:
            self._games.append(game)
        save_game_library(self._games)
        self._rebuild_game_rows()

    def _on_remove_game(self, game):
        self._games = [g for g in self._games if g["id"] != game["id"]]
        save_game_library(self._games)
        self._rebuild_game_rows()

    def _on_scan_steam_games(self, _row):
        """Scan for installed Steam games and add them to the library."""
        self._toast_ok("Scanning Steam library folders…")
        threading.Thread(target=self._scan_steam_worker, daemon=True).start()

    def _scan_steam_worker(self):
        """Worker thread to scan Steam library folders and appmanifest files."""
        steam_games = scan_steam_libraries()

        if not steam_games:
            GLib.idle_add(self._toast_ok, "No Steam games found")
            return

        # Add games that aren't already in the library
        existing_ids = {g["id"] for g in self._games}
        added = 0
        for sg in steam_games:
            gid = f"steam_{sg['appid']}"
            if gid not in existing_ids:
                self._games.append({
                    "id": gid,
                    "name": sg["name"],
                    "launch_type": "steam",
                    "target": sg["appid"],
                    "boost_mode": "performance",
                })
                added += 1

        if added > 0:
            GLib.idle_add(save_game_library, self._games)
            GLib.idle_add(self._rebuild_game_rows)
            GLib.idle_add(self._toast_ok, f"Added {added} Steam game(s) to library")
        else:
            GLib.idle_add(self._toast_ok, "No new Steam games found (already in library)")

    def _on_launch_game(self, game: dict):
        if self._active_monitor is not None:
            toast = Adw.Toast.new("A game is already being monitored — stop it first")
            toast.set_timeout(3)
            self._toast_overlay.add_toast(toast)
            return

        # Remember the current mode so we can restore it on exit
        self._pre_launch_mode = self._current_mode

        # Apply the game's configured boost mode before launching
        boost_mode = game.get("boost_mode", "performance")
        self._on_mode_switch(None, boost_mode)

        row, _ = self._game_rows.get(game["id"], (None, None))
        if row is not None:
            row.set_subtitle("Starting…")

        threading.Thread(target=self._launch_and_track, args=(game,), daemon=True).start()

    def _launch_and_track(self, game: dict):
        launch_type = game.get("launch_type", "direct")
        pid = None

        try:
            if launch_type == "steam":
                appid = game.get("target", "")
                before_pids = {int(p) for p in os.listdir("/proc") if p.isdigit()}
                subprocess.Popen(
                    ["steam", "-applaunch", appid],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                GLib.idle_add(self._set_game_subtitle, game["id"], "Detecting game process…")
                pid = find_new_process_after_launch(before_pids)
            else:
                exec_path = game.get("target", "")
                proc = subprocess.Popen(
                    [exec_path],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                pid = proc.pid
        except Exception as e:
            GLib.idle_add(self._on_launch_failed, game, str(e))
            return

        if pid is None:
            GLib.idle_add(self._on_launch_failed, game,
                           "Couldn't detect the game process — boost is still active, but live monitoring isn't available for this session.")
            return

        GLib.idle_add(self._start_monitoring, game, pid)

    def _on_launch_failed(self, game, err_msg):
        row, _ = self._game_rows.get(game["id"], (None, None))
        if row is not None:
            row.set_subtitle("Not running")
        toast = Adw.Toast.new(f"{game['name']}: {err_msg}")
        toast.set_timeout(5)
        self._toast_overlay.add_toast(toast)

    def _start_monitoring(self, game, pid):
        self._active_monitor = ProcessMonitor(pid)
        self._active_game_id = game["id"]

        row, _ = self._game_rows.get(game["id"], (None, None))
        if row is not None:
            row.set_subtitle("Running — 0:00, 0% CPU, 0 MB")
            row._raptor_play_btn.set_child(Gtk.Image.new_from_icon_name("media-playback-stop-symbolic"))
            row._raptor_play_btn.set_tooltip_text(f"Stop monitoring {game['name']}")

        self._monitor_start_time = time.time()
        self._monitor_timer_id = GLib.timeout_add_seconds(2, self._game_monitor_tick, game)

        toast = Adw.Toast.new(f"{game['name']} launched — boost active, now monitoring")
        toast.set_timeout(3)
        self._toast_overlay.add_toast(toast)

    def _set_game_subtitle(self, game_id, text):
        row, _ = self._game_rows.get(game_id, (None, None))
        if row is not None:
            row.set_subtitle(text)

    def _game_monitor_tick(self, game):
        if self._active_monitor is None:
            return False

        if not self._active_monitor.alive():
            self._on_game_exited(game)
            return False

        cpu, rss = self._active_monitor.sample()
        elapsed = int(time.time() - self._monitor_start_time)
        mins, secs = divmod(elapsed, 60)

        row, _ = self._game_rows.get(game["id"], (None, None))
        if row is not None:
            row.set_subtitle(f"Running — {mins}:{secs:02d}, {cpu:.0f}% CPU, {rss:.0f} MB")

        return True  # keep the timer running

    def _on_game_exited(self, game):
        row, _ = self._game_rows.get(game["id"], (None, None))
        if row is not None:
            row.set_subtitle("Not running")
            row._raptor_play_btn.set_child(Gtk.Image.new_from_icon_name("media-playback-start-symbolic"))
            row._raptor_play_btn.set_tooltip_text(f"Launch {game['name']}")

        self._active_monitor = None
        self._active_game_id = None

        if self._settings.get("auto_restore_after_game", True) and self._pre_launch_mode:
            self._on_mode_switch(None, self._pre_launch_mode)
            toast_msg = f"{game['name']} closed — restored {self._pre_launch_mode.title()} mode"
        else:
            toast_msg = f"{game['name']} closed"

        toast = Adw.Toast.new(toast_msg)
        toast.set_timeout(3)
        self._toast_overlay.add_toast(toast)
        self._pre_launch_mode = None

    def _on_stop_monitoring_only(self, game):
        """Stop watching a game without killing it — used when the user
        clicks the stop icon rather than actually closing the game."""
        if self._monitor_timer_id is not None:
            GLib.source_remove(self._monitor_timer_id)
            self._monitor_timer_id = None
        self._on_game_exited(game)

    def _update_mode_banner(self):
        label, desc, _, _ = PERFORMANCE_MODES[self._current_mode]
        self.mode_banner.set_title(f"Active mode: {label} — {desc}")

    def _refresh_mode_buttons(self):
        for key, (row, icon, check) in self._mode_btns.items():
            is_active = (key == self._current_mode)
            # Active row: show checkmark, full opacity, not clickable (already selected)
            check.set_visible(is_active)
            icon.set_opacity(1.0 if is_active else 0.4)
            icon.set_css_classes(["accent"] if is_active else [])
            row.set_opacity(1.0 if is_active else 0.65)
            # Sensitive=False on the active row prevents re-selecting same mode,
            # but ALL inactive rows remain fully clickable.
            row.set_sensitive(not is_active)

    def _switch_row(self, title, subtitle, default):
        row = Adw.SwitchRow()
        row.set_title(title)
        row.set_subtitle(subtitle)
        row.set_active(default)
        return row

    def _on_cortex_toggle(self, row, _param, pattern):
        if row.get_active():
            self._cortex_patterns.add(pattern)
        else:
            self._cortex_patterns.discard(pattern)
        threading.Thread(target=save_cortex_config, args=(self._cortex_patterns,), daemon=True).start()

    def _on_mode_switch(self, row, mode_key):
        # Do not display or persist a profile until the system confirms it.
        if getattr(self, "_mode_change_pending", False):
            return
        if mode_key == self._current_mode:
            return
        self._mode_change_pending = True
        for key, (mode_row, _icon, _check) in self._mode_btns.items():
            mode_row.set_sensitive(False)
        threading.Thread(target=self._apply_mode, args=(mode_key,), daemon=True).start()

    def _apply_mode(self, mode_key):
        result = run_cortex_helper("set-mode", mode_key)
        applied = result.returncode == 0
        detail = (result.stderr or result.stdout or "").strip()

        background_ok = True
        if applied and mode_key == "performance":
            # Pause only the optional process set selected in Cortex.
            game = run_cortex_helper("trim-background")
            background_ok = game.returncode == 0
            if not background_ok:
                detail = (game.stderr or game.stdout or "Game Mode setup failed").strip()
        elif applied:
            restore = run_cortex_helper("restore-background")
            background_ok = restore.returncode == 0
            if not background_ok:
                detail = (restore.stderr or restore.stdout or "Background restore failed").strip()

        gpu_note = ""
        if applied and self._settings.get("gpu_follows_mode", True):
            if os.path.exists("/usr/lib/raptor/gpu-detect.sh"):
                gpu_profile = MODE_TO_GPU_PROFILE.get(mode_key)
                if gpu_profile and get_gpu_profile() != gpu_profile:
                    gpu_ok, _gmsg = set_gpu_profile(gpu_profile)
                    gpu_note = " + GPU profile" if gpu_ok else " (GPU profile not changed)"
                    GLib.idle_add(self._refresh_gpu_profile)

        label = PERFORMANCE_MODES[mode_key][0]
        if not applied:
            msg = f"{label} was not applied; previous mode remains active. {detail[:180]}"
        elif not background_ok:
            msg = f"{label} power profile applied, but Game Mode/background handling failed: {detail[:180]}"
        else:
            msg = f"Mode set to {label}{gpu_note}"

        GLib.idle_add(self._on_mode_applied, mode_key, applied, msg)

    def _refresh_gpu_profile(self):
        """Tick the row matching the active profile on disk."""
        current = get_gpu_profile()
        for key, (row, check) in getattr(self, "_gfx_rows", {}).items():
            check.set_active(key == current)

    def _on_gpu_follow_toggle(self, row, _param):
        self._settings["gpu_follows_mode"] = row.get_active()
        threading.Thread(
            target=save_persistent_settings, args=(self._settings,), daemon=True
        ).start()
        if row.get_active():
            profile = MODE_TO_GPU_PROFILE.get(self._current_mode)
            if profile and get_gpu_profile() != profile:
                def work():
                    ok, msg = set_gpu_profile(profile)
                    GLib.idle_add(self._on_gpu_profile_done, ok, profile, msg)
                threading.Thread(target=work, daemon=True).start()

    def _on_gpu_profile(self, row, profile):
        if get_gpu_profile() == profile:
            return
        # Picking a profile by hand is an override: stop following the mode.
        follow = getattr(self, "gfx_follow_row", None)
        if follow is not None and follow.get_active():
            follow.set_active(False)
        def work():
            ok, msg = set_gpu_profile(profile)
            GLib.idle_add(self._on_gpu_profile_done, ok, profile, msg)
        threading.Thread(target=work, daemon=True).start()

    def _on_gpu_profile_done(self, ok, profile, msg):
        if not ok:
            self._toast_error(f"GPU profile change refused: {msg}")
            self._refresh_gpu_profile()
            return False
        self._refresh_gpu_profile()
        title = next((t for k, t, _ in GPU_PROFILES if k == profile), profile)
        self._toast_ok(f"GPU profile set to {title}")
        return False

    def _on_mode_applied(self, mode_key, applied, message):
        self._mode_change_pending = False
        if applied:
            self._current_mode = mode_key
            persist_mode(mode_key)
            self._update_mode_banner()
        self._refresh_mode_buttons()
        for key, (mode_row, _icon, _check) in self._mode_btns.items():
            mode_row.set_sensitive(key != self._current_mode)
        toast = Adw.Toast.new(message)
        toast.set_timeout(5 if not applied else 3)
        self._toast_overlay.add_toast(toast)
        self._refresh_stats()
        return False

    def _refresh_stats(self):
        """Start one worker per reading; each updates its own label when it finishes.

        Reading sysfs, hwmon, lspci or nvidia-smi can block for seconds on some hardware
        (ACPI thermal zones, a sleeping GPU, a slow EC). This used to run on the UI thread,
        before the window was even shown, so one slow sensor meant Cortex never opened and
        printed nothing. Now nothing here can block the UI, and a slow sensor delays only
        its own label."""
        # KDE Powerdevil can change the active profile independently of
        # Cortex. Poll PPD off the UI thread so the Cortex banner/buttons follow
        # the battery slider instead of showing a stale cached mode.
        if (not getattr(self, "_mode_change_pending", False)
                and not getattr(self, "_profile_sync_busy", False)):
            self._profile_sync_busy = True
            threading.Thread(target=self._sync_external_power_mode, daemon=True).start()

        readers = {
            "mem": (mem_used_mb, (0, 0)),
            "swap": (get_swap_usage, (0, 0)),
            "zram": (get_zram_usage, (0, 0, False)),
            "boost": (get_cpu_boost, None),
            "cpu_t": (get_cpu_temp, None),
            "freq": (get_cpu_freq_mhz, None),
            "gpu_t": (get_gpu_temp, None),
            "gpu_info": (get_gpu_summary, "GPU"),
            "fans": (get_fan_info, []),
        }
        busy = self.__dict__.setdefault("_stats_busy", set())
        for key, (fn, default) in readers.items():
            if key in busy:
                continue                      # previous reading still running: skip this tick
            busy.add(key)

            def work(key=key, fn=fn, default=default):
                try:
                    value = fn()
                except Exception:
                    value = default
                GLib.idle_add(self._apply_stats, {key: value})

            threading.Thread(target=work, daemon=True).start()
        return True

    def _sync_external_power_mode(self):
        mode = read_power_profile_mode()
        GLib.idle_add(self._apply_external_power_mode, mode)

    def _apply_external_power_mode(self, mode):
        self._profile_sync_busy = False
        if (mode in PERFORMANCE_MODES
                and not getattr(self, "_mode_change_pending", False)
                and mode != self._current_mode):
            self._current_mode = mode
            persist_mode(mode)
            self._refresh_mode_buttons()
            self._update_mode_banner()
        return False

    def _apply_stats(self, d):
        busy = self.__dict__.setdefault("_stats_busy", set())
        for k in d:
            busy.discard(k)
        if "mem" in d:
            used, total = d["mem"]
            if total > 0:
                ratio = used / total
                self.ram_bar.set_value(ratio)
                self.ram_label.set_text(f"{fmt_mb(used)} / {fmt_mb(total)}")
                if ratio > 0.85:
                    self.ram_bar.remove_css_class("success")
                    self.ram_bar.add_css_class("error")
                elif ratio > 0.65:
                    self.ram_bar.remove_css_class("error")
                    self.ram_bar.add_css_class("warning")
                else:
                    self.ram_bar.remove_css_class("error")
                    self.ram_bar.remove_css_class("warning")

        if "swap" in d:
            swap_used, swap_total = d["swap"]
            self.swap_label.set_text(
                f"{fmt_mb(swap_used)} / {fmt_mb(swap_total)}" if swap_total > 0 else "No swap")

        if "zram" in d:
            zram_orig, zram_total, zram_active = d["zram"]
            if zram_active:
                if zram_orig > 0:
                    ratio = zram_orig / max(zram_total, 1)
                    self.zram_label.set_text(f"{fmt_mb(zram_orig)} → {fmt_mb(zram_total)} ({ratio:.1f}x)")
                else:
                    self.zram_label.set_text(f"{fmt_mb(zram_total)} slot, idle")
            else:
                self.zram_label.set_text("Not active")

        if "boost" in d:
            boost = d["boost"]
            self.boost_label.set_text("Enabled ✓" if boost else "Disabled" if boost is not None else "N/A")

        if "cpu_t" in d:
            cpu_t = d["cpu_t"]
            self.cpu_temp_label.set_text(f"{cpu_t} °C" if cpu_t is not None else "N/A")
            self.cpu_temp_label.set_css_classes(
                ["error"] if cpu_t and cpu_t > 90
                else ["warning"] if cpu_t and cpu_t > 75
                else ["dim-label"])

        if "gpu_t" in d:
            gpu_t = d["gpu_t"]
            self.gpu_temp_label.set_text(f"{gpu_t} °C" if gpu_t is not None else "N/A")
            self.gpu_temp_label.set_css_classes(
                ["error"] if gpu_t and gpu_t > 95
                else ["warning"] if gpu_t and gpu_t > 80
                else ["dim-label"])

        if "gpu_info" in d:
            self.gpu_info_label.set_text(d["gpu_info"])
        if "fans" in d:
            fans = d["fans"]
            self.fan_label.set_text(
                "\n".join(f"{n}: {t}" for n, t in fans) if fans else "No fan sensors detected")

        if "freq" in d:
            freq = d["freq"]
            self.cpu_freq_label.set_text(
                f"{freq} MHz ({freq/1000:.2f} GHz)" if freq else "N/A")

        self.last_optimize_label.set_text(
            format_relative_time(self._settings.get("last_optimize_timestamp")))
        return False

    def on_quick_optimize(self, btn):
        """One-click optimization auto-tuned to current performance profile."""
        if self._running:
            return
        self._running = True
        self.run_btn.set_sensitive(False)
        self.spinner.start()

        # Auto-select options based on current performance mode
        # Safe defaults in every mode: no cache flush, compaction, forced swap,
        # zram recompression, or OOM-score changes during a one-click operation.
        opts = {"caches": True, "compact": False, "zram": False,
                "oom": False, "deep": False, "swap": False}

        before_used, before_total = mem_used_mb()
        threading.Thread(target=self._do_optimize, args=(opts, before_used, before_total), daemon=True).start()

    def on_optimize(self, btn):
        if self._running:
            return
        self._running = True
        self.run_btn.set_sensitive(False)
        self.spinner.start()
        opts = {
            "caches":  self.opt_caches.get_active(),
            "compact": self.opt_compact.get_active(),
            "zram":    self.opt_zram.get_active(),
            "oom":     self.opt_oom.get_active(),
            "deep":    self.opt_deep.get_active(),
            "swap":    self.opt_swap.get_active(),
        }
        before_used, before_total = mem_used_mb()
        threading.Thread(target=self._do_optimize, args=(opts, before_used, before_total), daemon=True).start()

    def _do_optimize(self, opts, before_used, before_total):
        result = run_cortex_helper(
            "1" if opts["caches"]  else "0",
            "1" if opts["compact"] else "0",
            "1" if opts["zram"]    else "0",
            "1" if opts["oom"]     else "0",
            "1" if opts["deep"]    else "0",
            "1" if opts["swap"]    else "0",
            "0", "0"
        )

        # Memory cleanup must never freeze desktop services. Game Mode owns
        # suspension through trim-background/restore-background exclusively.
        suspended = []
        self._suspended_now = []
        after_used, _ = mem_used_mb()
        freed = max(0, before_used - after_used)
        detail = (result.stderr or result.stdout or "").strip()
        GLib.idle_add(
            self._show_result, before_used, before_total, after_used, freed,
            suspended, result.returncode == 0, detail
        )

    def _show_result(self, before, total, after, freed, suspended, ok, detail):
        self._running = False
        self.run_btn.set_sensitive(True)
        self.spinner.stop()

        if ok:
            # Record only successful runs; failed helper calls must not look
            # like completed optimization work in the dashboard.
            self._settings["last_optimize_timestamp"] = time.time()
            threading.Thread(
                target=save_persistent_settings, args=(self._settings,), daemon=True
            ).start()

        self._refresh_stats()

        self.result_group.set_visible(True)
        self.result_row.set_title(f"Freed {fmt_mb(freed)}" if ok else "Optimization failed")
        self.result_row.set_subtitle(
            f"Before: {fmt_mb(before)} / {fmt_mb(total)}   After: {fmt_mb(after)} / {fmt_mb(total)}"
            + ("" if ok else f"   {detail[:180] or 'Check sudo and the system journal.'}"))
        if ok:
            self._toast_ok("Memory optimization completed")
        else:
            self._toast_error("Memory optimization failed; no success was recorded")

        if suspended:
            self.resume_btn.set_sensitive(True)
            self.sus_group.set_visible(True)
            child = self.sus_box.get_first_child()
            while child:
                nxt = child.get_next_sibling()
                self.sus_box.remove(child)
                child = nxt
            for name in suspended:
                lbl = Gtk.Label(label=f"  • {name}", xalign=0)
                lbl.add_css_class("dim-label")
                self.sus_box.append(lbl)
        else:
            self.sus_group.set_visible(False)

    def on_resume(self, btn):
        for _, pattern in ALL_SERVICES:
            if pattern in self._cortex_patterns:
                subprocess.run(["/usr/lib/raptor/safe-signal", "CONT", pattern], capture_output=True)
        self._suspended_now.clear()
        self.resume_btn.set_sensitive(False)
        self.sus_group.set_visible(False)
        threading.Thread(target=self._run_restore_background, daemon=True).start()


class GameEditDialog(Adw.Window):
    """Add or edit a single Game Library entry."""

    BOOST_MODES = [("performance", "Performance"), ("balanced", "Balanced"), ("power_saving", "Power Saving")]

    def __init__(self, parent, game: dict | None, on_save):
        super().__init__(transient_for=parent, modal=True)
        self._on_save = on_save
        self._editing = game is not None
        self._game = dict(game) if game else {
            "id": None, "name": "", "launch_type": "direct",
            "target": "", "boost_mode": "performance",
        }
        self.set_title("Edit Game" if self._editing else "Add a Game")
        self.set_default_size(420, 340)
        self._build_ui()

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)

        hb = Adw.HeaderBar()
        root.append(hb)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        content.set_margin_top(20)
        content.set_margin_bottom(20)
        content.set_margin_start(20)
        content.set_margin_end(20)
        root.append(content)

        group = Adw.PreferencesGroup()
        content.append(group)

        self.name_row = Adw.EntryRow(title="Game name")
        self.name_row.set_text(self._game.get("name", ""))
        group.add(self.name_row)

        self.launch_type_row = Adw.ComboRow(title="Launch method")
        launch_model = Gtk.StringList.new(["Direct executable", "Steam App ID"])
        self.launch_type_row.set_model(launch_model)
        self.launch_type_row.set_selected(0 if self._game.get("launch_type", "direct") == "direct" else 1)
        self.launch_type_row.connect("notify::selected", self._on_launch_type_changed)
        group.add(self.launch_type_row)

        self.target_row = Adw.EntryRow(title="Executable path")
        self.target_row.set_text(self._game.get("target", ""))
        group.add(self.target_row)

        browse_btn = Gtk.Button()
        browse_btn.set_child(Gtk.Image.new_from_icon_name("folder-open-symbolic"))
        browse_btn.add_css_class("flat")
        browse_btn.set_valign(Gtk.Align.CENTER)
        browse_btn.connect("clicked", self._on_browse_clicked)
        self.target_row.add_suffix(browse_btn)
        self._browse_btn = browse_btn

        self.boost_row = Adw.ComboRow(title="Boost mode on launch")
        self.boost_row.set_subtitle("Mode Cortex switches to when you launch this game")
        boost_model = Gtk.StringList.new([label for _key, label in self.BOOST_MODES])
        self.boost_row.set_model(boost_model)
        current_boost = self._game.get("boost_mode", "performance")
        idx = next((i for i, (k, _l) in enumerate(self.BOOST_MODES) if k == current_boost), 0)
        self.boost_row.set_selected(idx)
        group.add(self.boost_row)

        self._update_target_row_label()

        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btn_box.set_halign(Gtk.Align.END)
        btn_box.set_margin_top(8)
        content.append(btn_box)

        cancel_btn = Gtk.Button(label="Cancel")
        cancel_btn.connect("clicked", lambda _b: self.close())
        btn_box.append(cancel_btn)

        save_btn = Gtk.Button(label="Save")
        save_btn.add_css_class("suggested-action")
        save_btn.connect("clicked", self._on_save_clicked)
        btn_box.append(save_btn)

    def _update_target_row_label(self):
        is_direct = self.launch_type_row.get_selected() == 0
        self.target_row.set_title("Executable path" if is_direct else "Steam App ID")
        self._browse_btn.set_visible(is_direct)

    def _on_launch_type_changed(self, _row, _param):
        self._update_target_row_label()

    def _on_browse_clicked(self, _btn):
        dialog = Gtk.FileChooserDialog(
            title="Select Game Executable",
            transient_for=self,
            action=Gtk.FileChooserAction.OPEN,
        )
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Select", Gtk.ResponseType.OK)
        dialog.connect("response", self._on_file_chosen)
        dialog.present()

    def _on_file_chosen(self, dialog, response):
        if response == Gtk.ResponseType.OK:
            file = dialog.get_file()
            if file:
                self.target_row.set_text(file.get_path())
        dialog.close()

    def _on_save_clicked(self, _btn):
        name = self.name_row.get_text().strip()
        target = self.target_row.get_text().strip()
        if not name or not target:
            toast = Adw.Toast.new("Name and target are both required")
            toast.set_timeout(3)
            # Best effort — this dialog has no toast overlay of its own,
            # so surface it as a simple inline title change instead.
            self.set_title("Name and target are required")
            return

        is_direct = self.launch_type_row.get_selected() == 0
        boost_key, _label = self.BOOST_MODES[self.boost_row.get_selected()]

        game_id = self._game.get("id") or str(uuid.uuid4())
        result = {
            "id": game_id,
            "name": name,
            "launch_type": "direct" if is_direct else "steam",
            "target": target,
            "boost_mode": boost_key,
        }
        self._on_save(result)
        self.close()


if __name__ == "__main__":
    app = RaptorCortexApp()
    sys.exit(app.run(sys.argv))
PYEOF
chmod +x /usr/bin/raptor-cortex

# ── Launcher wrapper ──────────────────────────────────────────────────────────
cat << 'EOF' > /usr/bin/raptor-cortex-launcher
#!/bin/bash
# Starts Raptor Cortex. Everything it prints goes to ~/.cache/raptor-cortex.log, and if
# it fails to start a window says why, instead of the menu entry silently doing nothing.
export ADW_DISABLE_PORTAL=1
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/raptor-cortex.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
echo "== $(date '+%F %T')  Raptor Cortex starting  ($(python3 -V 2>&1), session: ${XDG_SESSION_TYPE:-unknown}) ==" > "$LOG"
/usr/bin/raptor-cortex "$@" >> "$LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && command -v zenity >/dev/null 2>&1; then
    zenity --error --no-markup --width=620 --title="Raptor Cortex could not start" \
        --text="Raptor Cortex stopped with an error (exit code $rc):\n\n$(tail -n 14 "$LOG")\n\nFull log: $LOG" 2>/dev/null
fi
exit $rc
EOF
chmod +x /usr/bin/raptor-cortex-launcher

# ── .desktop entry ────────────────────────────────────────────────────────────
mkdir -p /usr/share/applications
cat << 'EOF' > /usr/share/applications/raptor-cortex.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=Raptor Cortex
GenericName=Memory & Performance Manager
Comment=Unified RAM optimization, performance mode switching, and game mode — no password required
Exec=/usr/bin/raptor-cortex-launcher
Icon=raptor-cortex
Terminal=false
Categories=X-RaptorOS;System;Settings;
Keywords=cortex;memory;ram;optimize;performance;gaming;
StartupNotify=true
X-KDE-SubstituteUID=false
EOF

# ── Self-check ────────────────────────────────────────────────────────────────
# This installer writes its real payload through heredocs, so a malformed
# heredoc can silently install a truncated or missing file — and the app then
# simply does not open on the user's machine, with an empty build log to
# explain it. Verify each artifact actually landed and is non-empty, and fail
# the build if not.
RAPTOR_EXPECTED_PAYLOAD="
/usr/bin/raptor-cortex
/usr/bin/raptor-cortex-launcher
/usr/lib/raptor/cortex-helper
/usr/lib/raptor/cortex-apply-boot-mode
/usr/lib/raptor/safe-signal
/usr/lib/raptor/unfreeze
/usr/lib/raptor/gamemode-start
/usr/lib/raptor/gamemode-end
/usr/share/applications/raptor-cortex.desktop
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "CORTEX_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
# Validate generated programs, not merely their existence. This catches
# malformed heredocs before they can ship in an otherwise successful image.
for raptor_shell in \
    /usr/bin/raptor-cortex-launcher \
    /usr/lib/raptor/cortex-helper \
    /usr/lib/raptor/cortex-apply-boot-mode \
    /usr/lib/raptor/safe-signal \
    /usr/lib/raptor/unfreeze \
    /usr/lib/raptor/gamemode-start \
    /usr/lib/raptor/gamemode-end; do
    if ! bash -n "$raptor_shell"; then
        echo "CORTEX_SHELL_SYNTAX_ERROR:$raptor_shell" >&2
        exit 1
    fi
done
if ! python3 - <<'PY'
import ast
with open("/usr/bin/raptor-cortex", encoding="utf-8") as source:
    ast.parse(source.read(), filename="/usr/bin/raptor-cortex")
PY
then
    echo "CORTEX_PYTHON_SYNTAX_ERROR:/usr/bin/raptor-cortex" >&2
    exit 1
fi
echo "CORTEX_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
