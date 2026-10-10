#!/bin/bash
set -e

# =============================================================================
# Raptor Cortex v4.1 — Unified Memory & Performance Management
# • RAM optimization with page cache management, compaction, zram recompress
# • Background service trimming/restoring for gaming
# • Seamless performance mode switching (no login required)
# • Game mode auto-suspend/resume via Cortex patterns
# • CPU boost management (complements GPU Profiler)
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

# ── Suspended process set ─────────────────────────────────────────────────────
# Single source of truth for both trim-background and restore-background.
# These two MUST stay identical: any process stopped here and not CONT'd there
# stays SIGSTOP'd for the rest of the session (until reboot). Previously the two
# lists drifted and 7 processes were left frozen permanently.
#
# Package-transaction tools (dpkg, apt-get, unattended-upgrade) are deliberately
# ABSENT. SIGSTOPping dpkg mid-transaction holds the dpkg lock, and a lock left
# held wedges every subsequent apt invocation until reboot. packagekitd is
# handled by its own systemd stop below rather than SIGSTOP, which is safe
# because PackageKit releases its transaction lock on SIGTERM.
BACKGROUND_PROCS=(
    "tracker-miner" "tracker-store" "tracker3"
    "baloo_file" "baloo_file_extractor" "akonadi"
    "kded" "kdeconnectd" "gvfs" "zeitgeist"
    "tumblerd" "updatedb" "mlocate"
    "snapd" "evolution" "gnome-software"
)

# ── Hardware power helpers ────────────────────────────────────────────────────

_apply_pcie_aspm() {
    # powersave | performance | default
    local P="$1"
    [ -f /sys/module/pcie_aspm/parameters/policy ] && \
        echo "$P" > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
}

_apply_nvme_power() {
    # min_power | max_performance | auto
    local S="$1"
    for f in /sys/class/nvme/nvme*/power/control \
              /sys/bus/pci/devices/*/nvme/nvme*/power/control; do
        [ -f "$f" ] && echo "$S" > "$f" 2>/dev/null || true
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

_apply_epp() {
    # energy_performance_preference: power | balance_power | balance_performance | performance
    # This is the biggest single battery saver on Intel HWP and AMD P-state systems.
    # Sets a hardware-level hint that goes directly to the processor's internal
    # P-state controller, separate from the software governor.
    local EPP="$1"
    for cpu_pol in /sys/devices/system/cpu/cpufreq/policy*; do
        local f="$cpu_pol/energy_performance_preference"
        if [ -f "$f" ]; then
            echo "$EPP" > "$f" 2>/dev/null || true
        fi
    done
    # Intel energy_perf_bias: 0=performance, 15=power (legacy interface)
    if [ -f /sys/devices/system/cpu/cpu0/power/energy_perf_bias ]; then
        case "$EPP" in
            power)               BIAS=15 ;;
            balance_power)       BIAS=10 ;;
            balance_performance) BIAS=6  ;;
            performance)         BIAS=0  ;;
            *)                   BIAS=6  ;;
        esac
        for f in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
            echo "$BIAS" > "$f" 2>/dev/null || true
        done
    fi
}

_apply_cpu_max_freq_pct() {
    # Cap scaling_max_freq to a percentage of cpuinfo_max_freq.
    # Pass 100 to restore to physical maximum.
    local PCT="$1"
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
        MAX=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null || echo 0)
        if [ "$MAX" -gt 0 ]; then
            if [ "$PCT" -eq 100 ]; then
                echo "$MAX" > "$pol/scaling_max_freq" 2>/dev/null || true
            else
                TARGET=$(( MAX * PCT / 100 ))
                echo "$TARGET" > "$pol/scaling_max_freq" 2>/dev/null || true
            fi
        fi
    done
}

_apply_platform_profile() {
    # low-power | balanced | performance
    # Firmware-level power coordination: fan curves, VRM limits, thermal targets.
    # More effective than software tuning alone on supported laptops.
    local PROF="$1"
    if [ -f /sys/firmware/acpi/platform_profile ]; then
        # Map our names to platform_profile values
        case "$PROF" in
            power_saving) echo "low-power"    > /sys/firmware/acpi/platform_profile 2>/dev/null || true ;;
            balanced)     echo "balanced"     > /sys/firmware/acpi/platform_profile 2>/dev/null || true ;;
            performance)  echo "performance"  > /sys/firmware/acpi/platform_profile 2>/dev/null || true ;;
        esac
    fi
}

_apply_net_runtime_pm() {
    # Enable runtime power management for network devices.
    # This powers down the NIC hardware when idle — does NOT disconnect WiFi.
    # The driver keeps the association; the radio powers down between packets.
    local MODE="$1"   # auto | on
    for dev in /sys/class/net/*/device/power/control; do
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

# ── cgroup v2 memory.reclaim — the actual "free RAM now" lever ────────────────
# drop_caches only touches kernel-internal page/dentry/inode caches, which on
# a freshly-booted system are often small (tens of MB). The vast majority of
# "used" RAM on a gaming desktop is ANONYMOUS memory held by running apps —
# Firefox tabs, Discord/Vesktop, Steam, etc. memory.reclaim (kernel 5.10+,
# present on all Fedora/Bazzite kernels) asks the kernel to walk the LRU of
# every process in a cgroup, write back dirty pages, drop clean pages, and
# swap out cold anonymous pages to zram. This is what actually moves the
# "Freed XXX MB" number in the Cortex UI.
#
# NEVER write to the root cgroup's memory.reclaim — that walks ALL processes
# including system services and can reclaim pages a game is actively using.
# Scoped to user.slice: covers Firefox/Vesktop/Steam/etc., not the kernel
# or system daemons.
_reclaim_user_slice() {
    local amount="${1:-1073741824}"  # bytes; default 1 GiB request
    local wrote=0
    for f in /sys/fs/cgroup/user.slice/memory.reclaim \
             /sys/fs/cgroup/user.slice/user-*.slice/memory.reclaim \
             /sys/fs/cgroup/user.slice/user-*.slice/user@*.service/memory.reclaim; do
        if [ -w "$f" ]; then
            echo "$amount" > "$f" 2>/dev/null && wrote=1
        fi
    done
    return 0
}

# FIX: clear Powerdevil session action so switching to power-saver
# doesn't trigger a logout/suspend. Patches every user's config and
# tells the running daemon to reload.
_clear_powerdevil_session_action() {
    while IFS=: read -r _ _ uid _ _ home _; do
        [ "$uid" -lt 1000 ] && continue
        [ -d "$home" ] || continue
        PPRC="$home/.config/powermanagementprofilesrc"
        [ -f "$PPRC" ] || continue
        [ -f "${PPRC}.raptorbak" ] || cp "$PPRC" "${PPRC}.raptorbak"
        for grp in "Battery][SuspendSession" "LowBattery][SuspendSession" \
                   "AC][SuspendSession"; do
            if grep -q "\[$grp\]" "$PPRC" 2>/dev/null; then
                sed -i "/\[$grp\]/,/^\[/ s/^idleTime=.*/idleTime=0/"     "$PPRC" 2>/dev/null || true
                sed -i "/\[$grp\]/,/^\[/ s/^suspendType=.*/suspendType=0/" "$PPRC" 2>/dev/null || true
            fi
        done
        if grep -q "\[Battery\]\[HandleButtonEvents\]" "$PPRC" 2>/dev/null; then
            sed -i "/\[Battery\]\[HandleButtonEvents\]/,/^\[/ s/^powerButtonAction=.*/powerButtonAction=0/" \
                "$PPRC" 2>/dev/null || true
        fi
    done < /etc/passwd
    # Tell Powerdevil daemon to reload
    for uid in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $1}' || true); do
        # sudo + env: reliably passes the session bus path to the target user.
        # runuser does not inherit the session environment consistently on
        # Bazzite; bare env-prefix (VAR=x sudo ...) is not interpreted by sudo.
        RUNTIME_DIR="/run/user/$uid"
        if [ -d "$RUNTIME_DIR" ]; then
            sudo -u "#$uid" \
                env DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
                dbus-send --session \
                    --dest=org.kde.Solid.PowerManagement \
                    /org/kde/Solid/PowerManagement \
                    org.kde.Solid.PowerManagement.refreshStatus \
                    2>/dev/null || true
        fi
    done
}
case "$ACTION" in
    # ── RAM optimization flags ─────────────────────────────────────────────
    0|1|2|3|4|5|6|7|8)
        DO_CACHE="${1:-0}";  DO_COMPACT="${2:-0}"; DO_ZRAM="${3:-0}"
        DO_OOM="${4:-0}";    DO_DEEP="${5:-0}";    DO_SWAP="${6:-0}"
        DO_THP="${7:-0}";    DO_CPU="${8:-0}"

        if [ "$DO_CACHE" = "1" ]; then
            sync || true
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
            echo 2 > /proc/sys/vm/drop_caches 2>/dev/null || true
            echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
            # Reclaim ~1 GiB from running user apps (Firefox, Vesktop, Steam, etc.)
            _reclaim_user_slice 1073741824
        fi
        [ "$DO_COMPACT" = "1" ] && echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
        if [ "$DO_ZRAM" = "1" ]; then
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
            echo recompress > /sys/block/zram0/recompress 2>/dev/null || true
            echo writeback   > /sys/block/zram0/writeback   2>/dev/null || true
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
            echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
            sleep 0.5
            echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
            echo 1 > /proc/sys/kernel/numa_balancing 2>/dev/null || true
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
            echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
            # Deep clean: request a much larger reclaim (~3 GiB). The kernel
            # reclaims at most what's actually reclaimable — over-requesting
            # is harmless, it just means "give back everything you can".
            _reclaim_user_slice 3221225472
        fi
        if [ "$DO_SWAP" = "1" ]; then
            CURRENT=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 80)
            echo 100 > /proc/sys/vm/swappiness 2>/dev/null || true
            sleep 1
            echo "$CURRENT" > /proc/sys/vm/swappiness 2>/dev/null || true
        fi
        if [ "$DO_THP" = "1" ]; then
            echo madvise       > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
            echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
        fi
        [ "$DO_CPU" = "1" ] && echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
        ;;

    # ── Per-mode kernel tuning ─────────────────────────────────────────────
    set-mode)
        MODE="${2:-balanced}"

        # ── Unconditional reset BEFORE applying the target mode ──────────────
        # Guards against drift: if a previous mode switch partially failed to
        # restore EPP / max frequency / platform profile (e.g. one sysfs write
        # silently failed), the system could stay stuck throttled even after
        # switching to Performance or Balanced. This block always runs first,
        # bringing the CPU to a full-power known state, before the target
        # mode's case below applies whatever throttling IT wants. This means
        # every mode switch is a full reset + reapply, never an incremental
        # patch on top of unknown prior state.
        _apply_cpu_max_freq_pct 100
        _apply_epp balance_performance
        echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true

        case "$MODE" in
            power_saving)
                # FIX: clear Powerdevil logout action BEFORE switching profile
                _clear_powerdevil_session_action

                echo 180  > /proc/sys/vm/swappiness                2>/dev/null || true
                echo 5    > /proc/sys/vm/dirty_ratio               2>/dev/null || true
                echo 2    > /proc/sys/vm/dirty_background_ratio    2>/dev/null || true
                # Longer writeback: 150 s means fewer storage controller wake-ups.
                # Storage (especially NVMe) goes into deep low-power states between
                # writes; longer intervals = more time in deep sleep.
                echo 15000 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
                echo 60000 > /proc/sys/vm/dirty_expire_centisecs    2>/dev/null || true
                # laptop_mode=5: more aggressive disk caching, even less frequent
                # actual writes to storage (5 is max useful value on modern kernels)
                echo 5    > /proc/sys/vm/laptop_mode                2>/dev/null || true

                # CPU: governor + turbo off
                echo 0 > /sys/devices/system/cpu/cpufreq/boost      2>/dev/null || true
                for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                    echo powersave > "$gov" 2>/dev/null || true
                done

                # EPP = power: tells the HWP/AMD-pstate hardware controller to
                # strongly prefer efficiency. This is the single biggest battery
                # saver on Intel (12th gen+) and AMD (Ryzen 4000+) — can cut CPU
                # power draw 20-40% vs governor alone. powersave governor without
                # EPP still lets the CPU hit high P-states under burst load.
                _apply_epp power

                # Cap max frequency to 65% of physical max — prevents high-freq
                # bursts under light loads. Restore with _apply_cpu_max_freq_pct 100
                _apply_cpu_max_freq_pct 65

                # Firmware-level power profile: coordinates fan curves, VRM limits,
                # and thermal targets at the ACPI/EC level. More effective than any
                # single software setting on supported laptops (ThinkPad, ASUS, etc.)
                _apply_platform_profile power_saving

                echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

                _apply_pcie_aspm       powersave
                _apply_nvme_power      min_power
                _apply_usb_autosuspend 1
                _apply_runtime_pm      auto
                _apply_sata_link_power min_power
                _apply_audio_powersave 1

                # HDA audio powersave controller: separate from power_save flag.
                # Allows the HD-audio controller itself (not just the codec) to
                # power down — saves ~0.5-1 W on systems with HDA audio hardware.
                echo Y > /sys/module/snd_hda_intel/parameters/power_save_controller                     2>/dev/null || true

                # HDA audio powersave controller: separate from power_save flag.
                # Allows the HD-audio controller itself (not just the codec) to
                # power down — saves ~0.5-1 W on systems with HDA audio hardware.
                echo Y > /sys/module/snd_hda_intel/parameters/power_save_controller                     2>/dev/null || true

                # Network device runtime PM: powers down NIC hardware between packets.
                # Does NOT disconnect WiFi — the driver keeps the association alive;
                # only the radio hardware powers down during idle periods.
                _apply_net_runtime_pm auto

                # WiFi power save: enable 802.11 power save mode. The AP buffers
                # frames for the client during sleep periods. Safe for most APs.
                for iface in /sys/class/net/wl*; do
                    [ -d "$iface" ] || continue
                    iw dev "$(basename "$iface")" set power_save on 2>/dev/null || true
                done



                # Display backlight: reduce to 50% on battery (if supported).
                # This is the single biggest display power saver.
                for bl in /sys/class/backlight/*/brightness; do
                    [ -f "$bl" ] || continue
                    max_bl="${bl%/brightness}/max_brightness"
                    [ -f "$max_bl" ] || continue
                    max_val=$(cat "$max_bl" 2>/dev/null || echo 100)
                    target=$((max_val / 2))
                    echo "$target" > "$bl" 2>/dev/null || true
                done

                powerprofilesctl set power-saver 2>/dev/null || true
                ;;

            balanced)
                # swappiness=30: lean toward keeping anonymous memory in RAM
                # while still allowing some swapping for memory pressure relief.
                echo 30   > /proc/sys/vm/swappiness                2>/dev/null || true
                echo 20   > /proc/sys/vm/dirty_ratio               2>/dev/null || true
                echo 8    > /proc/sys/vm/dirty_background_ratio    2>/dev/null || true
                echo 1500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
                echo 1500 > /proc/sys/vm/dirty_expire_centisecs    2>/dev/null || true
                echo 0    > /proc/sys/vm/laptop_mode               2>/dev/null || true

                echo 0 > /sys/devices/system/cpu/cpufreq/boost     2>/dev/null || true
                for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                    echo schedutil > "$gov" 2>/dev/null || true
                done

                # Restore EPP and max_freq if coming from power_saving
                _apply_epp              balance_power
                _apply_cpu_max_freq_pct 100
                _apply_platform_profile balanced

                echo madvise       > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
                echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

                _apply_pcie_aspm       default
                _apply_nvme_power      auto
                _apply_usb_autosuspend 1
                _apply_runtime_pm      auto
                _apply_sata_link_power medium_power
                _apply_audio_powersave 1

                # Restore audio controller to on (balanced doesn't need it saving power)
                echo N > /sys/module/snd_hda_intel/parameters/power_save_controller                     2>/dev/null || true
                _apply_net_runtime_pm on

                powerprofilesctl set balanced 2>/dev/null || true
                ;;

            performance)
                # swappiness=5: strongly prefer keeping all game data in RAM.
                # dirty_ratio=25: buffer up to 25% of RAM as dirty pages before
                # any synchronous write stall — games write saves/logs rarely so
                # a large dirty window avoids I/O stalls during gameplay.
                echo 5   > /proc/sys/vm/swappiness                 2>/dev/null || true
                echo 25  > /proc/sys/vm/dirty_ratio                2>/dev/null || true
                echo 10  > /proc/sys/vm/dirty_background_ratio     2>/dev/null || true
                echo 500 > /proc/sys/vm/dirty_writeback_centisecs  2>/dev/null || true
                echo 500 > /proc/sys/vm/dirty_expire_centisecs     2>/dev/null || true
                echo 0   > /proc/sys/vm/laptop_mode                2>/dev/null || true

                # EPP = performance: full hardware P-state performance mode
                _apply_epp              performance
                # Restore max freq to physical maximum (in case power_saving capped it)
                _apply_cpu_max_freq_pct 100
                _apply_platform_profile performance

                # Restore audio controller and net PM to full power
                echo N > /sys/module/snd_hda_intel/parameters/power_save_controller                     2>/dev/null || true
                _apply_net_runtime_pm on
                echo 500 > /proc/sys/vm/dirty_writeback_centisecs  2>/dev/null || true
                echo 500 > /proc/sys/vm/dirty_expire_centisecs     2>/dev/null || true
                echo 0   > /proc/sys/vm/laptop_mode                2>/dev/null || true

                echo 1 > /sys/devices/system/cpu/cpufreq/boost     2>/dev/null || true
                for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                    echo performance > "$gov" 2>/dev/null || true
                done
                echo madvise       > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
                echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

                _apply_pcie_aspm       performance
                _apply_nvme_power      max_performance
                _apply_usb_autosuspend 0
                _apply_runtime_pm      on
                _apply_sata_link_power max_performance
                _apply_audio_powersave 0

                sync || true
                echo 1 > /proc/sys/vm/drop_caches    2>/dev/null || true
                echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true

                powerprofilesctl set performance 2>/dev/null || true
                ;;
        esac
        ;;

    # ── Background trimming for gaming ─────────────────────────────────────
    trim-background)
        sync || true
        echo 1 > /proc/sys/vm/drop_caches    2>/dev/null || true
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
        # Reclaim ~1.5 GiB from background apps before the game starts —
        # frees real RAM the game can use, not just kernel caches.
        _reclaim_user_slice 1610612736
        # irqbalance: switch to per-CPU interrupt affinity for gaming.
        # Stops irqbalance from moving NIC/audio IRQs away from the CPU
        # the game is running on mid-frame.
        systemctl stop irqbalance.service 2>/dev/null || true
        # Hold /dev/cpu_dma_latency open for the duration of gaming.
        # IMPORTANT: closing the file descriptor immediately releases the PM
        # QoS constraint — a one-shot `echo 0 | tee` opens, writes, and closes
        # the FD in the same instant, so the constraint was released before
        # the game even started. This was a complete no-op in earlier versions.
        # Fixed: a backgrounded subshell holds the FD open via `exec`, keeping
        # the constraint active (CPU stays at C1 or shallower, ~100-300µs less
        # wake latency) until resume-background removes the sentinel file.
        rm -f /run/raptor-cpu-dma-latency-held
        (
            exec 9<>/dev/cpu_dma_latency
            echo 0 >&9
            touch /run/raptor-cpu-dma-latency-held
            while [ -f /run/raptor-cpu-dma-latency-held ]; do
                sleep 5
            done
        ) &>/dev/null &
        disown
        for proc in "${BACKGROUND_PROCS[@]}"; do
            pkill -STOP "$proc" 2>/dev/null || true
        done
        for proc in baloo tracker zeitgeist; do
            for pid in $(pgrep -x "$proc" 2>/dev/null); do
                ionice -c 3 -p "$pid" 2>/dev/null || true
                renice +15 -p "$pid" 2>/dev/null || true
            done
        done
        systemctl stop snapd.service   2>/dev/null || true
        systemctl stop fstrim.service  2>/dev/null || true
        # PackageKit is a daemon, so stop it by service rather than SIGSTOP:
        # it releases its transaction lock cleanly on SIGTERM.
        systemctl stop packagekit.service 2>/dev/null || true
        balooctl6 suspend 2>/dev/null || balooctl suspend 2>/dev/null || true
        echo 6000 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
        ;;

    # ── Background restoration after gaming ────────────────────────────────
    restore-background)
        # Continue all previously stopped background processes
        for proc in "${BACKGROUND_PROCS[@]}"; do
            pkill -CONT "$proc" 2>/dev/null || true
        done
        # Resume Baloo indexing
        balooctl6 resume 2>/dev/null || balooctl resume 2>/dev/null || true
        # Restart systemd services that were stopped during trim
        systemctl start snapd.service  2>/dev/null || true
        systemctl start packagekit.service 2>/dev/null || true
        systemctl start fstrim.timer  2>/dev/null || true
        systemctl start irqbalance.service 2>/dev/null || true
        systemctl start fstrim.service 2>/dev/null || true
        # Release the cpu_dma_latency hold — removes the sentinel file, which
        # the held-open subshell is polling for; it then exits and closes the
        # FD, releasing the PM QoS constraint so the CPU can idle normally again.
        rm -f /run/raptor-cpu-dma-latency-held
        echo 500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
        # Ensure ionice/renice are reset for indexers
        for proc in baloo tracker zeitgeist; do
            for pid in $(pgrep -x "$proc" 2>/dev/null); do
                ionice -c 0 -p "$pid" 2>/dev/null || true
                renice 0 -p "$pid" 2>/dev/null || true
            done
        done
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
Description=Raptor Cortex — apply persisted performance mode
# After gpu-detect.sh has run: both write scaling_governor, and Cortex's mode
# is the one the user explicitly chose, so it must win.
After=raptor-gpu-profile.service
# Do not delay the session; a failure here must never block login.
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
# Raptor Cortex — services to suspend during gaming
baloo_file
tracker
akonadiserver
kwalletd
kdeconnectd
kio_thumbnail
kactivitymanagerd
plasma-geolocation
kbuildsycoca
zeitgeist
evolution-data
gvfsd-metadata
colord
pipewire-media-session
EOF

# ── Gamemode hooks ────────────────────────────────────────────────────────────
cat << 'EOF' > /usr/lib/raptor/gamemode-start
#!/bin/bash
sudo /usr/lib/raptor/cortex-helper 1 1 1 1 0 0 0 1 2>/dev/null || true
sudo /usr/lib/raptor/cortex-helper trim-background 2>/dev/null || true
CONFIG=/etc/raptor/cortex-suspend.conf
[ -f "$CONFIG" ] || exit 0
while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$pattern" in "#"*) continue ;; esac
    pgrep -f "$pattern" > /dev/null 2>&1 && pkill -STOP -f "$pattern" 2>/dev/null || true
done < "$CONFIG"
EOF
chmod +x /usr/lib/raptor/gamemode-start

cat << 'EOF' > /usr/lib/raptor/gamemode-end
#!/bin/bash
CONFIG=/etc/raptor/cortex-suspend.conf
[ -f "$CONFIG" ] || exit 0
while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$pattern" in "#"*) continue ;; esac
    pkill -CONT -f "$pattern" 2>/dev/null || true
done < "$CONFIG"
# Also restore any processes from the default cortex config
CONFIG2=/etc/raptor/cortex-suspend.conf.default
[ -f "$CONFIG2" ] || exit 0
while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    case "$pattern" in "#"*) continue ;; esac
    pkill -CONT -f "$pattern" 2>/dev/null || true
done < "$CONFIG2"
sudo /usr/lib/raptor/cortex-helper restore-background 2>/dev/null || true
EOF
chmod +x /usr/lib/raptor/gamemode-end

# Enable the boot-mode unit for every user. This is what makes the GUI's
# "Apply selected mode on every boot" toggle actually do something; without
# the enable the unit exists but never runs and the mode resets on reboot.
systemctl --global enable raptor-cortex-mode.service 2>/dev/null || true

# ── Gamemode config ───────────────────────────────────────────────────────────
mkdir -p /etc/gamemode.d
cat << 'EOF' > /etc/gamemode.d/raptor-cortex.ini
[general]
renice=10
inhibit_screensaver=1
softrealtime=auto
reaper_freq=5

[gpu]
apply_gpu_optimisations=accept-responsibility
gpu_device=0
amd_performance_level=high

[custom]
start=/usr/lib/raptor/gamemode-start
end=/usr/lib/raptor/gamemode-end
EOF

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

ALL_SERVICES = [
    # ── KDE / indexing ────────────────────────────────────────────────────────
    ("Baloo file indexer",      "baloo_file"),
    ("Akonadi server",          "akonadiserver"),
    ("KDE Connect daemon",      "kdeconnectd"),
    ("Thumbnail generator",     "kio_thumbnail"),
    ("Activity manager",        "kactivitymanagerd"),
    ("KDE wallet daemon",       "kwalletd"),
    ("Plasma geolocation",      "plasma-geolocation"),
    ("KDE sycoca builder",      "kbuildsycoca"),
    # ── GNOME / cross-desktop ─────────────────────────────────────────────────
    ("Evolution data server",   "evolution-data"),
    ("Zeitgeist daemon",        "zeitgeist"),
    ("GVFS metadata",           "gvfsd-metadata"),
    ("Colour management",       "colord"),
    # ── System daemons safe to pause while gaming ─────────────────────────────
    ("Package manager daemon",  "packagekitd"),      # apt/dnf background checks
    ("KDE crash handler",       "drkonqi"),           # crash reporter, unneeded in-game
    ("Bluetooth OBEX",          "obexd"),             # BT file transfer daemon
    ("Smart card daemon",       "pcscd"),             # rarely used on gaming desktops
    ("Printer discovery",       "cups-browsed"),      # network printer scan
    # ── Audio session (suspend last — restoring audio can be slow) ────────────
    ("PipeWire media session",  "pipewire-media-session"),
]

PERFORMANCE_MODES = {
    "power_saving": (
        "Power Saving",
        "Reduces CPU governor, dirty writeback, PCIe ASPM on, NVMe min power. Battery slider works normally.",
        "battery-low-symbolic",
        "#f5c211",
    ),
    "balanced": (
        "Balanced",
        "Moderate tuning with schedutil governor, USB autosuspend, medium SATA power.",
        "media-playlist-shuffle-symbolic",
        "#3584e4",
    ),
    "performance": (
        "Performance",
        "CPU boost on, performance governor, PCIe/NVMe max performance, background trimmed.",
        "starred-symbolic",
        "#2ec27e",
    ),
}


def detect_system_mode() -> str:
    """Read the persisted Cortex mode from ~/.config/raptor-cortex-mode.
    Falls back to 'balanced' if not set."""
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


def get_cpu_temp():
    """Return CPU temperature in °C, or None if unavailable."""
    # Try x86_pkg_temp first (most accurate on Intel/AMD)
    for zone in sorted(os.listdir("/sys/class/thermal")):
        path = f"/sys/class/thermal/{zone}"
        try:
            with open(f"{path}/type") as f:
                t = f.read().strip()
            if t in ("x86_pkg_temp", "k10temp", "acpitz", "cpu-thermal"):
                with open(f"{path}/temp") as f:
                    return int(f.read().strip()) // 1000
        except Exception:
            continue
    # Fall back: first thermal zone that looks sane
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            t = int(f.read().strip()) // 1000
            return t if 10 < t < 120 else None
    except Exception:
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
    ("powersave", "Power Saving", "Low power level, shader cache off — for battery or heat"),
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
    """Return GPU temperature in °C from hwmon or AMD sysfs."""
    # AMD: check hwmon for devices advertising 'amdgpu'
    try:
        for hwmon in sorted(os.listdir("/sys/class/hwmon")):
            name_path = f"/sys/class/hwmon/{hwmon}/name"
            with open(name_path) as f:
                name = f.read().strip()
            if name in ("amdgpu", "radeon"):
                for label_cand in ("temp1_input", "temp2_input"):
                    tp = f"/sys/class/hwmon/{hwmon}/{label_cand}"
                    if os.path.exists(tp):
                        with open(tp) as f:
                            return int(f.read().strip()) // 1000
    except Exception:
        pass
    # NVIDIA: try nvidia-smi
    try:
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=temperature.gpu", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=2
        )
        if r.returncode == 0:
            return int(r.stdout.strip())
    except Exception:
        pass
    return None


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
    # First-run defaults: suspend crash handler, indexers, and update daemons
    # These are safe to suspend and provide measurable gains
    if not patterns:
        defaults = {
            "drkonqi",          # KDE crash handler
            "baloo_file",       # file indexer
            "akonadiserver",    # PIM server
            "kdeconnectd",      # KDE Connect
            "packagekitd",      # package updates
            "gvfsd-metadata",   # GVFS metadata
            "kactivitymanagerd", # activity tracking
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
        GLib.timeout_add_seconds(2, self._refresh_stats)
        self._refresh_stats()

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
            "Applies kernel tuning instantly — CPU, PCIe ASPM, NVMe, SATA, USB, audio power. "
            "Battery tray slider remains functional.")
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
        # GPU Profiler; it lives here now because it is the same decision as the
        # CPU boost mode above, and splitting it out meant two windows and two
        # launchers for one machine.
        gfx_group = Adw.PreferencesGroup(
            title="Graphics",
            description="Tuning for your GPU. Applies immediately and survives reboot.")

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

        self.add(gfx_group)

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

        # Quick Optimize — one click, auto-tuned to current performance profile
        quick_row = Adw.ActionRow(title="Quick Optimize")
        quick_row.set_subtitle("One-click memory optimization tuned to your current performance profile")
        quick_row.set_activatable(True)
        quick_icon = Gtk.Image.new_from_icon_name("system-run-symbolic")
        quick_icon.set_pixel_size(18)
        quick_row.add_prefix(quick_icon)
        quick_row.connect("activated", self.on_quick_optimize)
        opts_group.add(quick_row)

        advanced_expander = Adw.ExpanderRow(title="Advanced Options")
        advanced_expander.set_subtitle("Choose exactly what runs — off by default, Quick Optimize above covers most cases")
        opts_group.add(advanced_expander)

        self.opt_caches  = self._switch_row("Drop caches + reclaim app memory",
                                             "Frees kernel caches AND asks running apps (Firefox, Vesktop, Steam) to release cold pages",
                                             True)
        advanced_expander.add_row(self.opt_caches)
        self.opt_compact = self._switch_row("Memory compaction",                 "Reduces fragmentation",                          True)
        advanced_expander.add_row(self.opt_compact)
        self.opt_zram    = self._switch_row("zram recompress",                   "Re-squeeze compressed swap pages",               True)
        advanced_expander.add_row(self.opt_zram)
        self.opt_swap    = self._switch_row("Swap pressure flush",               "Push cold pages to ZRAM swap (aggressive — use before gaming)",
                                             False)
        advanced_expander.add_row(self.opt_swap)
        self.opt_oom     = self._switch_row("Adjust OOM scores",                 "Protect KDE shell; make browsers killable",      True)
        advanced_expander.add_row(self.opt_oom)
        self.opt_deep    = self._switch_row("Deep Clean (slow)",                 "Flush hugepages + NUMA + slab caches + reclaim 3 GiB", False)
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
            "Switch to Performance mode, drop caches, reclaim ~1.5 GB from browser/Discord")
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
        """One click: Performance mode + cache drop + 1.5 GB cgroup reclaim."""
        self._on_mode_switch(None, "performance")
        opts = {"caches": True, "compact": False, "zram": False,
                "swap": False, "oom": True, "deep": False, "thp": False, "cpu": False}
        before, total = mem_used_mb()
        threading.Thread(
            target=self._do_optimize, args=(opts, before, total), daemon=True
        ).start()
        toast = Adw.Toast.new("Pre-Game Boost applied — Performance mode active")
        toast.set_timeout(3)
        self._toast_overlay.add_toast(toast)

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
        steam_games = []
        # Common Steam library locations
        steam_paths = [
            os.path.expanduser("~/.local/share/Steam/steamapps"),
            os.path.expanduser("~/.steam/steam/steamapps"),
            "/mnt/*/SteamLibrary/steamapps",
            "/media/*/SteamLibrary/steamapps",
            "/run/media/*/SteamLibrary/steamapps",
        ]
        import glob
        for base in steam_paths:
            for path in glob.glob(base):
                if not os.path.isdir(path):
                    continue
                for manifest in glob.glob(os.path.join(path, "appmanifest_*.acf")):
                    try:
                        with open(manifest) as f:
                            content = f.read()
                        # Parse the ACF file (simple key-value format)
                        appid = None
                        name = None
                        for line in content.splitlines():
                            line = line.strip().strip('"')
                            if line.startswith('"appid"'):
                                appid = line.split('"')[-1]
                            elif line.startswith('"name"'):
                                name = line.split('"')[-1]
                        if appid and name:
                            steam_games.append({"appid": appid, "name": name})
                    except Exception:
                        continue

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
        # Update UI immediately so it feels responsive
        self._current_mode = mode_key
        self._refresh_mode_buttons()
        self._update_mode_banner()
        # Persist the selection so next app launch reads the right mode
        persist_mode(mode_key)
        # Apply the kernel tuning in a background thread
        threading.Thread(target=self._apply_mode, args=(mode_key,), daemon=True).start()

    def _apply_mode(self, mode_key):
        ok = True

        result = subprocess.run(["sudo", HELPER, "set-mode", mode_key],
                                capture_output=True, text=True)
        if result.returncode != 0:
            ok = False

        if mode_key == "performance":
            subprocess.run(["sudo", HELPER, "1", "1", "1", "1", "0", "0", "0", "1"],
                           capture_output=True)
            subprocess.run(["sudo", HELPER, "trim-background"],
                           capture_output=True)
        elif mode_key == "balanced":
            subprocess.run(["sudo", HELPER, "1", "1", "0", "1", "0", "0", "0", "0"],
                           capture_output=True)
        elif mode_key == "power_saving":
            subprocess.run(["sudo", HELPER, "1", "0", "0", "0", "0", "0", "0", "0"],
                           capture_output=True)

        label = PERFORMANCE_MODES[mode_key][0]
        if ok:
            msg = f"Mode set to {label}"
        else:
            msg = f"{label} applied (powerprofilesctl unavailable, kernel tuning still active)"

        GLib.idle_add(self._on_mode_applied, msg)

    def _refresh_gpu_profile(self):
        """Tick the row matching the active profile on disk."""
        current = get_gpu_profile()
        for key, (row, check) in getattr(self, "_gfx_rows", {}).items():
            check.set_active(key == current)

    def _on_gpu_profile(self, row, profile):
        if get_gpu_profile() == profile:
            return
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

    def _on_mode_applied(self, message):
        toast = Adw.Toast.new(message)
        toast.set_timeout(3)
        self._toast_overlay.add_toast(toast)
        self._refresh_stats()
        return False

    def _refresh_stats(self):
        used, total = mem_used_mb()
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

        swap_used, swap_total = get_swap_usage()
        self.swap_label.set_text(
            f"{fmt_mb(swap_used)} / {fmt_mb(swap_total)}" if swap_total > 0 else "No swap")

        zram_orig, zram_total, zram_active = get_zram_usage()
        if zram_active:
            if zram_orig > 0:
                ratio = zram_orig / max(zram_total, 1)
                self.zram_label.set_text(f"{fmt_mb(zram_orig)} → {fmt_mb(zram_total)} ({ratio:.1f}x)")
            else:
                self.zram_label.set_text(f"{fmt_mb(zram_total)} slot, idle")
        else:
            self.zram_label.set_text("Not active")

        boost = get_cpu_boost()
        self.boost_label.set_text("Enabled ✓" if boost else "Disabled" if boost is not None else "N/A")

        cpu_t = get_cpu_temp()
        self.cpu_temp_label.set_text(f"{cpu_t} °C" if cpu_t is not None else "N/A")
        self.cpu_temp_label.set_css_classes(
            ["error"] if cpu_t and cpu_t > 90
            else ["warning"] if cpu_t and cpu_t > 75
            else ["dim-label"])

        gpu_t = get_gpu_temp()
        self.gpu_temp_label.set_text(f"{gpu_t} °C" if gpu_t is not None else "N/A")
        self.gpu_temp_label.set_css_classes(
            ["error"] if gpu_t and gpu_t > 95
            else ["warning"] if gpu_t and gpu_t > 80
            else ["dim-label"])

        freq = get_cpu_freq_mhz()
        self.cpu_freq_label.set_text(
            f"{freq} MHz ({freq/1000:.2f} GHz)" if freq else "N/A")

        self.last_optimize_label.set_text(
            format_relative_time(self._settings.get("last_optimize_timestamp")))
        return True

    def on_quick_optimize(self, btn):
        """One-click optimization auto-tuned to current performance profile."""
        if self._running:
            return
        self._running = True
        self.run_btn.set_sensitive(False)
        self.spinner.start()

        # Auto-select options based on current performance mode
        mode = self._current_mode
        if mode == "performance":
            opts = {"caches": True, "compact": True, "zram": True, "oom": True, "deep": False, "swap": True}
        elif mode == "power_saving":
            opts = {"caches": True, "compact": True, "zram": True, "oom": True, "deep": False, "swap": False}
        else:  # balanced
            opts = {"caches": True, "compact": True, "zram": True, "oom": True, "deep": False, "swap": False}

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
        subprocess.run([
            "sudo", HELPER,
            "1" if opts["caches"]  else "0",
            "1" if opts["compact"] else "0",
            "1" if opts["zram"]    else "0",
            "1" if opts["oom"]     else "0",
            "1" if opts["deep"]    else "0",
            "1" if opts["swap"]    else "0",
            "0", "0"
        ], capture_output=True)

        suspended = []
        for name, pattern in ALL_SERVICES:
            if pattern not in self._cortex_patterns:
                continue
            result = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
            if result.returncode == 0:
                subprocess.run(["pkill", "-STOP", "-f", pattern], capture_output=True)
                suspended.append(name)

        self._suspended_now = suspended
        after_used, _ = mem_used_mb()
        freed = max(0, before_used - after_used)
        GLib.idle_add(self._show_result, before_used, before_total, after_used, freed, suspended)

    def _show_result(self, before, total, after, freed, suspended):
        self._running = False
        self.run_btn.set_sensitive(True)
        self.spinner.stop()

        # Record the timestamp for any completed optimization run — manual
        # "Optimize Memory Now", Pre-Game Boost, and Scheduled Cleanup all
        # converge on this method, so this one write covers all three.
        self._settings["last_optimize_timestamp"] = time.time()
        threading.Thread(
            target=save_persistent_settings, args=(self._settings,), daemon=True
        ).start()


        self._refresh_stats()

        self.result_group.set_visible(True)
        self.result_row.set_title(f"Freed {fmt_mb(freed)}")
        self.result_row.set_subtitle(
            f"Before: {fmt_mb(before)} / {fmt_mb(total)}   After: {fmt_mb(after)} / {fmt_mb(total)}")

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
                subprocess.run(["pkill", "-CONT", "-f", pattern], capture_output=True)
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
export ADW_DISABLE_PORTAL=1
exec /usr/bin/raptor-cortex "$@"
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
/usr/lib/raptor/cortex-helper
/usr/lib/raptor/cortex-apply-boot-mode
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
echo "CORTEX_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
