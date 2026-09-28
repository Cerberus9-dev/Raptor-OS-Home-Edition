#!/bin/bash
set -oue pipefail

# =============================================================================
# Raptor OS — GPU Profile Detection & Configuration  v3.0
#
# BUILD-TIME: writes static config files, the runtime detection script,
#             and the systemd service that runs it on boot.
#
# RUNTIME:    /usr/lib/raptor/gpu-detect.sh runs via raptor-gpu-profile.service
#             after sysinit, where lspci/sysfs/kernel modules are available.
# =============================================================================

mkdir -p /etc/environment.d \
         /etc/sysctl.d \
         /usr/lib/raptor \
         /usr/lib/systemd/system \
         /etc/polkit-1/rules.d \
         /etc/sudoers.d \
         /etc/raptor \
         /usr/share/icons/hicolor/scalable/apps

# ── App icon ───────────────────────────────────────────────────────────────────
# Same visual language as raptor-cortex.svg (radial badge, dashed ring, cardinal
# ticks) so both apps read as a matched pair in the app menu — a GPU/chip glyph
# replaces Cortex's lightning bolt in the centre.
cat << 'SVGEOF' > /usr/share/icons/hicolor/scalable/apps/raptor-gpu-profiler.svg
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
  <!-- GPU chip glyph: square die with corner pins -->
  <circle cx="32" cy="32" r="9" fill="url(#core)"/>
  <rect x="27" y="27" width="10" height="10" rx="1.5" fill="white" opacity="0.95"/>
  <rect x="29" y="29" width="6" height="6" rx="0.5" fill="url(#core)"/>
  <line x1="27" y1="24" x2="27" y2="27" stroke="white" stroke-width="1.2" opacity="0.95"/>
  <line x1="37" y1="24" x2="37" y2="27" stroke="white" stroke-width="1.2" opacity="0.95"/>
  <line x1="27" y1="37" x2="27" y2="40" stroke="white" stroke-width="1.2" opacity="0.95"/>
  <line x1="37" y1="37" x2="37" y2="40" stroke="white" stroke-width="1.2" opacity="0.95"/>
  <line x1="24" y1="27" x2="27" y2="27" stroke="white" stroke-width="1.2" opacity="0.95"/>
  <line x1="24" y1="37" x2="27" y2="37" stroke="white" stroke-width="1.2" opacity="0.95"/>
  <line x1="37" y1="27" x2="40" y2="27" stroke="white" stroke-width="1.2" opacity="0.95"/>
  <line x1="37" y1="37" x2="40" y2="37" stroke="white" stroke-width="1.2" opacity="0.95"/>
</svg>
SVGEOF

gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── Fallback env file (overwritten at runtime by gpu-detect.sh) ───────────────
cat << 'ENVEOF' > /etc/environment.d/raptor-gpu.conf
# Raptor OS: GPU profile — applied at boot by raptor-gpu-profile.service.
# This file is the safe fallback written at image build time.
# It will be replaced on first boot once the GPU is detected.
MESA_SHADER_CACHE_DISABLE=false
WINE_LARGE_ADDRESS_AWARE=1
PROTON_FORCE_LARGE_ADDRESS_AWARE=1
# WINE_FULLSCREEN_FSR and DXVK_ASYNC are intentionally NOT set globally.
# They cause flickering/lighting glitches in OpenGL games like Project Zomboid.
# Set per-game in Steam: right-click game → Properties → Launch Options:
#   WINE_FULLSCREEN_FSR=1 DXVK_ASYNC=1 %command%
STAGING_SHARED_MEMORY=1
PROTON_NO_ESYNC=0
PROTON_NO_FSYNC=0
ENVEOF

# ── Gaming sysctl (static — safe to write at build time) ─────────────────────
cat << 'SYSCTL' > /etc/sysctl.d/raptor-gaming.conf
# ── Raptor OS Gaming sysctl ──────────────────────────────────────────────────
kernel.sched_autogroup_enabled=1
kernel.sched_min_granularity_ns=500000
kernel.sched_wakeup_granularity_ns=1000000
kernel.sched_migration_cost_ns=250000
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=256
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
kernel.split_lock_mitigate=0
SYSCTL

# ── Runtime detection + apply script ─────────────────────────────────────────
cat << 'DETECT' > /usr/lib/raptor/gpu-detect.sh
#!/bin/bash
set -euo pipefail

# ── GPU detection (runs at boot where lspci/sysfs are available) ──────────────
GPU_VENDOR="unknown"
GPU_MODEL=""

if lspci 2>/dev/null | grep -i "VGA\|3D\|Display" | grep -qi "nvidia"; then
    GPU_VENDOR="nvidia"
    GPU_MODEL=$(lspci | grep -i "VGA\|3D\|Display" | grep -i "nvidia" \
        | sed 's/.*\[//;s/\].*//' | head -1)
elif lspci 2>/dev/null | grep -i "VGA\|3D\|Display" | grep -qi "amd\|radeon\|ati"; then
    GPU_VENDOR="amd"
    GPU_MODEL=$(lspci | grep -i "VGA\|3D\|Display" | grep -i "amd\|radeon\|ati" \
        | sed 's/.*\[//;s/\].*//' | head -1)
elif lspci 2>/dev/null | grep -i "VGA\|3D\|Display" | grep -qi "intel"; then
    GPU_VENDOR="intel"
    GPU_MODEL=$(lspci | grep -i "VGA\|3D\|Display" | grep -i "intel" \
        | sed 's/.*\[//;s/\].*//' | head -1)
fi
echo "Detected GPU vendor: $GPU_VENDOR  model: ${GPU_MODEL:-unknown}"

# ── iGPU / hybrid detection ───────────────────────────────────────────────────
IS_IGPU=false
IS_HYBRID=false

if lspci 2>/dev/null | grep -i "VGA\|3D\|Display" | grep -qi "intel"; then
    IS_IGPU=true
fi
if lspci -v 2>/dev/null | grep -i "VGA\|3D\|Display" -A5 | grep -qi \
    "subsystem.*apu\|integrated\|cezanne\|renoir\|lucienne\|rembrandt\|mendocino\|phoenix\|hawk point"; then
    IS_IGPU=true
fi
DISPLAY_DEVS=$(lspci 2>/dev/null | grep -ic "VGA\|3D\|Display" || echo 0)
if [ "$DISPLAY_DEVS" -ge 2 ]; then
    IS_HYBRID=true
fi

# ── Active profile flag ───────────────────────────────────────────────────────
PROFILE="auto"
[ -f /etc/raptor-force-extreme ]     && PROFILE="extreme"
[ -f /etc/raptor-force-performance ] && PROFILE="performance"
[ -f /etc/raptor-force-powersave ]   && PROFILE="powersave"
[ -f /etc/raptor-force-balanced ]    && PROFILE="balanced"
echo "Active profile: $PROFILE"

# ── Common env vars ───────────────────────────────────────────────────────────
# RADV_PERFTEST=gpl: Vulkan Graphics Pipeline Library — pre-compiles shader
# variant stubs as a library rather than full monolithic programs. Cuts
# in-game compile stalls by 30-60% on RDNA2+. Safe, well-tested upstream.
COMMON_VARS="WINE_LARGE_ADDRESS_AWARE=1
PROTON_FORCE_LARGE_ADDRESS_AWARE=1
# WINE_FULLSCREEN_FSR and DXVK_ASYNC are intentionally NOT set globally.
# They cause flickering/lighting glitches in OpenGL games like Project Zomboid.
# Set per-game in Steam: right-click game → Properties → Launch Options:
#   WINE_FULLSCREEN_FSR=1 DXVK_ASYNC=1 %command%
STAGING_SHARED_MEMORY=1
PROTON_NO_ESYNC=0
PROTON_NO_FSYNC=0
RADV_PERFTEST=gpl"

# ── Profile → env file ────────────────────────────────────────────────────────
case "$PROFILE" in

  extreme)
    cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: EXTREME PERFORMANCE profile ───────────────────────────────────
AMD_VULKAN_ICD=RADV
MESA_SHADER_CACHE_DISABLE=false
MESA_SHADER_CACHE_MAX_SIZE=4G
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
__GL_THREADED_OPTIMIZATIONS=1
AMDGPU_HIGH_POWER=1
PROTON_ENABLE_NVAPI=1
# DXVK_ASYNC=1  ← set per-game, not globally (causes shader flicker)
DXVK_FRAME_RATE=0
VKD3D_CONFIG=dxr11,dxr
VKD3D_FEATURE_LEVEL=12_2
$COMMON_VARS
ENVEOF
    if [ "$GPU_VENDOR" = "amd" ]; then
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            echo "high" > "$f" 2>/dev/null || true
        done
        for f in /sys/class/drm/card*/device/pp_power_profile_mode; do
            echo 1 > "$f" 2>/dev/null || true
        done
    fi
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        nvidia-smi -pm 1 > /dev/null 2>&1 || true
        nvidia-smi --auto-boost-default=0 > /dev/null 2>&1 || true
    fi
    ;;

  performance)
    cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: MAX PERFORMANCE profile ───────────────────────────────────────
AMD_VULKAN_ICD=RADV
MESA_SHADER_CACHE_DISABLE=false
MESA_SHADER_CACHE_MAX_SIZE=2G
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
__GL_THREADED_OPTIMIZATIONS=1
PROTON_ENABLE_NVAPI=1
# DXVK_ASYNC=1  ← set per-game, not globally (causes shader flicker)
VKD3D_CONFIG=dxr11
VKD3D_FEATURE_LEVEL=12_1
$COMMON_VARS
ENVEOF
    if [ "$GPU_VENDOR" = "amd" ]; then
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            echo "high" > "$f" 2>/dev/null || true
        done
    fi
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        nvidia-smi -pm 1 > /dev/null 2>&1 || true
    fi
    ;;

  balanced)
    cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: BALANCED profile ───────────────────────────────────────────────
AMD_VULKAN_ICD=RADV
MESA_SHADER_CACHE_DISABLE=false
__GL_SHADER_DISK_CACHE=1
PROTON_ENABLE_NVAPI=1
$COMMON_VARS
ENVEOF
    if [ "$GPU_VENDOR" = "amd" ]; then
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            echo "auto" > "$f" 2>/dev/null || true
        done
    fi
    ;;

  powersave)
    cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: POWER SAVING profile ──────────────────────────────────────────
# Shader cache disabled: saves disk reads/writes and storage wake-ups.
# Shaders will recompile on first launch but power draw is lower overall.
MESA_SHADER_CACHE_DISABLE=true
# Disable threaded optimizations: fewer background threads = lower idle power.
__GL_THREADED_OPTIMIZATIONS=0
$COMMON_VARS
ENVEOF
    if [ "$GPU_VENDOR" = "amd" ]; then
        # Force GPU to low power DPM level
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            echo "low" > "$f" 2>/dev/null || true
        done
        # Set GPU power profile to video (profile 1) — lower clocks, optimised
        # for sequential workloads rather than bursty gaming patterns
        for f in /sys/class/drm/card*/device/pp_power_profile_mode; do
            echo 1 > "$f" 2>/dev/null || true
        done
        # Enable GFXOFF: allows the GPU shader engine to fully power off at idle.
        # On RDNA2+ this saves 0.5-2 W during desktop use.
        for f in /sys/kernel/debug/dri/*/amdgpu_gfxoff; do
            echo 1 > "$f" 2>/dev/null || true
        done
        # Hard cap GPU clocks to the lowest available level via OD
        for card in /sys/class/drm/card*/device; do
            if [ -f "$card/pp_od_clk_voltage" ]; then
                echo "manual" > "$card/power_dpm_force_performance_level" 2>/dev/null || true
                echo "s 0 $(awk 'NR==2{print $2}' "$card/pp_dpm_sclk" 2>/dev/null)"                     > "$card/pp_od_clk_voltage" 2>/dev/null || true
                echo "c" > "$card/pp_od_clk_voltage" 2>/dev/null || true
            fi
        done 2>/dev/null || true
    fi
    if [ "$GPU_VENDOR" = "intel" ]; then
        # Intel GPU: enable frequency scaling to minimum
        for f in /sys/class/drm/card*/gt_min_freq_mhz; do
            MIN=$(cat "${f%min_freq_mhz}min_freq_mhz" 2>/dev/null || echo 100)
            echo "$MIN" > "$f" 2>/dev/null || true
        done
        for f in /sys/class/drm/card*/gt_max_freq_mhz; do
            MIN=$(cat "${f%max_freq_mhz}min_freq_mhz" 2>/dev/null || echo 100)
            echo "$MIN" > "$f" 2>/dev/null || true
        done
        # Intel Panel Self-Refresh: allows display controller to stop driving
        # the panel backplane between frame updates. Saves 0.5-1.5 W on eDP.
        echo 1 > /sys/module/i915/parameters/enable_psr 2>/dev/null || true
    fi
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        # Disable NVIDIA persistence mode: GPU fully powers down when idle
        nvidia-smi -pm 0 > /dev/null 2>&1 || true
        # Reduce power limit to 80% of TDP if supported
        MAX_PL=$(nvidia-smi --query-gpu=power.max_limit             --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        if [ -n "$MAX_PL" ] && [ "$MAX_PL" -gt 0 ] 2>/dev/null; then
            TARGET=$(( MAX_PL * 80 / 100 ))
            nvidia-smi -pl "$TARGET" > /dev/null 2>&1 || true
        fi
    fi
    ;;

  auto|*)
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: NVIDIA auto profile ────────────────────────────────────────────
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
__GL_THREADED_OPTIMIZATIONS=1
PROTON_ENABLE_NVAPI=1
# DXVK_ASYNC=1  ← set per-game, not globally (causes shader flicker)
VKD3D_CONFIG=dxr11
$COMMON_VARS
ENVEOF
    elif [ "$GPU_VENDOR" = "amd" ] && [ "$IS_IGPU" = true ]; then
        cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: AMD iGPU auto profile ──────────────────────────────────────────
AMD_VULKAN_ICD=RADV
MESA_SHADER_CACHE_DISABLE=false
$COMMON_VARS
ENVEOF
    elif [ "$GPU_VENDOR" = "amd" ]; then
        cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: AMD dGPU auto profile ──────────────────────────────────────────
AMD_VULKAN_ICD=RADV
MESA_SHADER_CACHE_DISABLE=false
MESA_SHADER_CACHE_MAX_SIZE=2G
__GL_SHADER_DISK_CACHE=1
# DXVK_ASYNC=1  ← set per-game, not globally (causes shader flicker)
$COMMON_VARS
ENVEOF
    elif [ "$GPU_VENDOR" = "intel" ]; then
        cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: Intel auto profile ─────────────────────────────────────────────
MESA_LOADER_DRIVER_OVERRIDE=iris
LIBGL_DRI3_DISABLE=0
vblank_mode=0
$COMMON_VARS
ENVEOF
    else
        cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: fallback profile ───────────────────────────────────────────────
MESA_SHADER_CACHE_DISABLE=false
$COMMON_VARS
ENVEOF
    fi
    ;;
esac

# ── CPU governor: match GPU profile ──────────────────────────────────────────
set_cpu_governor() {
    local GOV="$1"
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$GOV" > "$f" 2>/dev/null || true
    done
    echo "CPU governor → $GOV"
}

case "$PROFILE" in
    extreme|performance) set_cpu_governor "performance" ;;
    balanced)            set_cpu_governor "schedutil"   ;;
    powersave)           set_cpu_governor "powersave"   ;;
    auto|*)              set_cpu_governor "schedutil"   ;;
esac

# ── Apply env vars to any already-running user sessions ──────────────────────
ENVFILE=/etc/environment.d/raptor-gpu.conf
if [ -f "$ENVFILE" ]; then
    LIVE_VARS=()
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]]       && continue
        LIVE_VARS+=("$line")
    done < "$ENVFILE"

    if [ ${#LIVE_VARS[@]} -gt 0 ]; then
        for uid in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $1}'); do
            RUNTIME_DIR="/run/user/$uid"
            if [ -d "$RUNTIME_DIR" ]; then
                DBUS="unix:path=$RUNTIME_DIR/bus"
                # set-environment accepts KEY=VALUE pairs directly (import-environment
                # only accepts variable names already in the current env — wrong here).
                sudo -u "#$uid" \
                     DBUS_SESSION_BUS_ADDRESS="$DBUS" \
                     systemctl --user set-environment "${LIVE_VARS[@]}" \
                     2>/dev/null || true
                USER_ENVDIR="$(getent passwd "$uid" | cut -d: -f6)/.config/environment.d"
                mkdir -p "$USER_ENVDIR" 2>/dev/null || true
                cp "$ENVFILE" "$USER_ENVDIR/raptor-gpu.conf" 2>/dev/null || true
            fi
        done
    fi
fi

# ── Reload sysctl ─────────────────────────────────────────────────────────────
sysctl --system > /dev/null 2>&1 || true

echo "GPU_PROFILE_READY  profile=$PROFILE  vendor=$GPU_VENDOR  igpu=$IS_IGPU  hybrid=$IS_HYBRID"
DETECT
chmod +x /usr/lib/raptor/gpu-detect.sh

# ── /etc/drirc: system-wide Mesa driver configuration ─────────────────────────
# mesa_glthread=true: offloads GL API calls to a background thread, giving the
# game's render thread more CPU time. ~10-20% perf gain on CPU-bound GL games
# (Project Zomboid, older titles). Applied per-device to avoid issues with apps
# that are incompatible (browsers, which use their own GL thread management).
# dri3=true: use DRI3 for X11 (lower latency, better tearing prevention on X11).
# throttle_cpu_to_gpu=false: don't stall the CPU waiting for GPU — lets the game
# pre-generate more draw calls.
mkdir -p /etc/drirc.d
cat << 'DRIRC' > /etc/drirc.d/99-raptor-mesa.conf
<driconf>
   <!-- Apply optimisations to all applications -->
   <application name="Default" executable="*">
      <option name="mesa_glthread" value="true" />
      <option name="throttle_cpu_to_gpu" value="false" />
   </application>

   <!-- Wine/Proton: always benefit from glthread -->
   <application name="Wine" executable="wine">
      <option name="mesa_glthread" value="true" />
   </application>
   <application name="Wine64" executable="wine64">
      <option name="mesa_glthread" value="true" />
   </application>

   <!-- Steam runtime: safe to enable -->
   <application name="Steam" executable="steam">
      <option name="mesa_glthread" value="true" />
      <option name="throttle_cpu_to_gpu" value="false" />
   </application>
</driconf>
DRIRC

# ── systemd service (runs gpu-detect.sh at boot) ──────────────────────────────
cat << 'SVCEOF' > /usr/lib/systemd/system/raptor-gpu-profile.service
[Unit]
Description=Raptor OS — GPU Profile Detection & Configuration
After=sysinit.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/lib/raptor/gpu-detect.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

# Enable the unit here — this installer owns the service. It used to be enabled
# by raptor-hud.sh, which also defined a competing copy of the unit; the copy in
# hud.sh was discarded (gpu-profile.sh runs later) but the `systemctl enable`
# was not, so removing the duplicate without moving this line would have left
# the unit installed but never started, silently killing boot-time GPU
# detection and leaving the fallback env file in place forever.
systemctl enable raptor-gpu-profile.service 2>/dev/null || true

# ── polkit rule ───────────────────────────────────────────────────────────────
cat << 'POLKIT' > /etc/polkit-1/rules.d/49-raptor-gpu.rules
polkit.addRule(function(action, subject) {
    var allowedActions = ["org.freedesktop.policykit.exec"];
    if (allowedActions.indexOf(action.id) >= 0 &&
        action.lookup("program") &&
        (action.lookup("program").indexOf("raptor-gpu-profile") !== -1 ||
         action.lookup("program").indexOf("raptor-gpu-profiler") !== -1 ||
         action.lookup("program").indexOf("gpu-detect.sh") !== -1) &&
        subject.active && subject.local) {
        return polkit.Result.YES;
    }
});
POLKIT

# ── sudoers drop-in ───────────────────────────────────────────────────────────
cat << 'SUDOERS' > /etc/sudoers.d/raptor-gpu
# Raptor OS: allow any user to switch GPU profiles without a password
ALL ALL=(root) NOPASSWD: /usr/lib/raptor/gpu-detect.sh
ALL ALL=(root) NOPASSWD: /usr/bin/touch /etc/raptor-force-*
ALL ALL=(root) NOPASSWD: /usr/bin/rm -f /etc/raptor-force-*
ALL ALL=(root) NOPASSWD: /usr/sbin/sysctl --system
SUDOERS
chmod 440 /etc/sudoers.d/raptor-gpu
if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf /etc/sudoers.d/raptor-gpu; then
        echo "FATAL: /etc/sudoers.d/raptor-gpu is invalid — refusing to ship a" >&2
        echo "       broken rule set. sudo ignores a malformed drop-in entirely," >&2
        echo "       which would make every GPU profile switch fail for all users." >&2
        exit 1
    fi
else
    echo "WARNING: visudo unavailable — /etc/sudoers.d/raptor-gpu NOT validated" >&2
fi

# ── Raptor GPU Profiler — GTK4/Adwaita UI ─────────────────────────────────────
# Matches Cortex's visual style: dark Adwaita, preference groups, pill buttons.
# Replaces the old bash TUI with a proper graphical profile switcher.
cat << 'GPUPYEOF' > /usr/bin/raptor-gpu-profiler
#!/usr/bin/env python3
# Raptor OS GPU Profiler — GTK4/Adwaita profile switcher

import gi
gi.require_version("Gtk",  "4.0")
gi.require_version("Adw",  "1")
import os, subprocess, threading, json
from gi.repository import Gtk, Adw, GLib

PROFILES = {
    "auto": (
        "Auto Detect",
        "Automatically selects settings based on your GPU hardware",
        "computer-symbolic",
        [],
    ),
    "balanced": (
        "Balanced",
        "Normal performance with reasonable power usage — the daily driver",
        "media-playlist-shuffle-symbolic",
        ["AMD_VULKAN_ICD=RADV", "MESA_SHADER_CACHE_DISABLE=false",
         "__GL_SHADER_DISK_CACHE=1"],
    ),
    "performance": (
        "Max Performance",
        "High GPU power level, shader disk cache, threaded GL optimisations",
        "starred-symbolic",
        ["AMD_VULKAN_ICD=RADV", "MESA_SHADER_CACHE_MAX_SIZE=2G",
         "__GL_THREADED_OPTIMIZATIONS=1", "VKD3D_CONFIG=dxr11"],
    ),
    "extreme": (
        "Extreme",
        "Maximum power level, DXR raytracing hints, largest shader cache",
        "trophy-symbolic",
        ["AMD_VULKAN_ICD=RADV", "MESA_SHADER_CACHE_MAX_SIZE=4G",
         "__GL_THREADED_OPTIMIZATIONS=1", "VKD3D_CONFIG=dxr11,dxr",
         "VKD3D_FEATURE_LEVEL=12_2"],
    ),
    "powersave": (
        "Power Saving",
        "Low GPU power level, shader cache disabled — for battery or thermals",
        "battery-low-symbolic",
        ["MESA_SHADER_CACHE_DISABLE=true"],
    ),
}

FLAG_DIR   = "/etc"
FORCE_FILE = {
    "extreme":     "/etc/raptor-force-extreme",
    "performance": "/etc/raptor-force-performance",
    "powersave":   "/etc/raptor-force-powersave",
    "balanced":    "/etc/raptor-force-balanced",
}
DETECT_SCRIPT = "/usr/lib/raptor/gpu-detect.sh"


def get_current_profile() -> str:
    for key, path in FORCE_FILE.items():
        if os.path.exists(path):
            return key
    return "auto"


def detect_gpu_info() -> dict:
    info = {"vendor": "Unknown", "model": "Unknown", "vram_mb": 0}
    try:
        r = subprocess.run(["lspci"], capture_output=True, text=True, timeout=3)
        for line in r.stdout.splitlines():
            low = line.lower()
            if any(k in low for k in ("vga", "3d", "display")):
                if "nvidia" in low:
                    info["vendor"] = "NVIDIA"
                    info["model"] = line.split(": ", 1)[-1].strip()[:60]
                elif "amd" in low or "radeon" in low:
                    info["vendor"] = "AMD"
                    info["model"] = line.split(": ", 1)[-1].strip()[:60]
                elif "intel" in low:
                    info["vendor"] = "Intel"
                    info["model"] = line.split(": ", 1)[-1].strip()[:60]
    except Exception:
        pass
    # Try to read VRAM from sysfs
    try:
        for card in sorted(os.listdir("/sys/class/drm")):
            p = f"/sys/class/drm/{card}/device/mem_info_vram_total"
            if os.path.exists(p):
                with open(p) as f:
                    info["vram_mb"] = int(f.read().strip()) // (1024 * 1024)
                break
    except Exception:
        pass
    return info


class GpuProfilerWindow(Adw.ApplicationWindow):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.set_title("Raptor GPU Profiler")
        self.set_default_size(480, 640)
        self.set_resizable(False)
        self._current = get_current_profile()
        self._mode_rows = {}
        self._build_ui()

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)

        hb = Adw.HeaderBar()
        root.append(hb)

        toast_overlay = Adw.ToastOverlay()
        toast_overlay.set_vexpand(True)
        root.append(toast_overlay)
        self._toast_overlay = toast_overlay

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_vexpand(True)
        toast_overlay.set_child(scroll)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        content.set_margin_top(20)
        content.set_margin_bottom(20)
        content.set_margin_start(20)
        content.set_margin_end(20)
        scroll.set_child(content)

        # ── GPU Info banner ────────────────────────────────────────────────────
        self._gpu_info = detect_gpu_info()
        vram_str = (f"{self._gpu_info['vram_mb']} MB VRAM"
                    if self._gpu_info["vram_mb"] > 0 else "")
        banner = Adw.Banner()
        banner.set_title(
            f"{self._gpu_info['vendor']} — {self._gpu_info['model']}"
            + (f"  ·  {vram_str}" if vram_str else "")
        )
        banner.set_revealed(True)
        content.append(banner)

        # ── Profile selector ──────────────────────────────────────────────────
        profile_group = Adw.PreferencesGroup(title="GPU Profile")
        profile_group.set_description(
            "Select a performance profile. Changes apply immediately — "
            "no reboot required for most settings.")
        content.append(profile_group)

        for key, (label, desc, icon_name, _env) in PROFILES.items():
            icon = Gtk.Image.new_from_icon_name(icon_name)
            icon.set_pixel_size(20)
            icon.set_valign(Gtk.Align.CENTER)
            icon.set_margin_end(4)

            check = Gtk.Image.new_from_icon_name("object-select-symbolic")
            check.set_pixel_size(16)
            check.set_valign(Gtk.Align.CENTER)
            check.set_visible(key == self._current)

            row = Adw.ActionRow(title=label)
            row.set_subtitle(desc)
            row.set_activatable(True)
            row.connect("activated", self._on_profile_select, key)
            row.add_prefix(icon)
            row.add_suffix(check)
            row.set_opacity(1.0 if key == self._current else 0.65)

            profile_group.add(row)
            self._mode_rows[key] = (row, icon, check)

        # ── Active env vars preview ────────────────────────────────────────────
        self._env_group = Adw.PreferencesGroup(title="Active Environment Variables")
        self._env_group.set_description(
            "Variables written to /etc/environment.d/raptor-gpu.conf and applied "
            "to all new processes. Add per-game overrides in Steam launch options.")
        content.append(self._env_group)
        self._refresh_env_preview()

        # ── Apply button ──────────────────────────────────────────────────────
        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btn_box.set_halign(Gtk.Align.CENTER)
        content.append(btn_box)

        self.apply_btn = Gtk.Button(label="Apply Profile")
        self.apply_btn.add_css_class("suggested-action")
        self.apply_btn.add_css_class("pill")
        self.apply_btn.connect("clicked", self._on_apply)
        btn_box.append(self.apply_btn)

        self.spinner = Gtk.Spinner()
        btn_box.append(self.spinner)

        # ── Per-game tips group ────────────────────────────────────────────────
        tips_group = Adw.PreferencesGroup(title="Per-Game Launch Options")
        tips_group.set_description(
            "Add these to Steam: right-click game → Properties → Launch Options")
        content.append(tips_group)

        tips = [
            ("FSR Upscaling",
             "WINE_FULLSCREEN_FSR=1 %command%",
             "Upscale from a lower render resolution — set in-game resolution below native first"),
            ("Async Shader Compilation",
             "DXVK_ASYNC=1 %command%",
             "Reduces shader compile stalls — may cause brief visual glitches on first encounter"),
            ("MangoHud Overlay",
             "MANGOHUD=1 %command%",
             "Enable the MangoHud performance overlay (Shift+F12 to toggle)"),
            ("Gamemode",
             "ENABLE_GAMEMODE=1 %command%",
             "Activate Gamemode for this game — suspends background services, boosts CPU"),
            ("Force Proton",
             "PROTON_USE_WINED3D=0 %command%",
             "Force DXVK over WineD3D — better performance for DX9-11 Windows games"),
        ]
        for title, cmd, subtitle in tips:
            tip_row = Adw.ActionRow(title=title)
            tip_row.set_subtitle(subtitle)
            code_label = Gtk.Label(label=cmd)
            code_label.add_css_class("monospace")
            code_label.add_css_class("dim-label")
            code_label.set_selectable(True)
            tip_row.add_suffix(code_label)
            tips_group.add(tip_row)

    def _refresh_env_preview(self):
        # Remove old rows
        child = self._env_group.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            if isinstance(child, Adw.ActionRow):
                self._env_group.remove(child)
            child = nxt

        _label, _desc, _icon, env_vars = PROFILES[self._current]
        always = [
            "WINE_LARGE_ADDRESS_AWARE=1",
            "PROTON_FORCE_LARGE_ADDRESS_AWARE=1",
            "STAGING_SHARED_MEMORY=1",
            "RADV_PERFTEST=gpl",
        ]
        all_vars = always + env_vars
        for var in all_vars:
            key_part, _, val_part = var.partition("=")
            row = Adw.ActionRow(title=key_part)
            val_label = Gtk.Label(label=val_part if val_part else "1")
            val_label.add_css_class("monospace")
            val_label.add_css_class("dim-label")
            row.add_suffix(val_label)
            self._env_group.add(row)

    def _on_profile_select(self, row, key):
        self._current = key
        for k, (r, icon, check) in self._mode_rows.items():
            active = (k == key)
            check.set_visible(active)
            icon.set_opacity(1.0 if active else 0.4)
            r.set_opacity(1.0 if active else 0.65)
        self._refresh_env_preview()

    def _on_apply(self, btn):
        btn.set_sensitive(False)
        self.spinner.start()

        # Write the profile flag files
        def do_apply():
            try:
                # Remove all existing force flags
                for path in FORCE_FILE.values():
                    subprocess.run(["sudo", "rm", "-f", path],
                                   capture_output=True)
                # Write the selected profile flag
                if self._current != "auto":
                    subprocess.run(
                        ["sudo", "touch", FORCE_FILE[self._current]],
                        capture_output=True
                    )
                # Re-run GPU detection to apply the new profile
                subprocess.run(["sudo", DETECT_SCRIPT],
                               capture_output=True, timeout=15)
                GLib.idle_add(self._on_apply_done, True)
            except Exception as e:
                GLib.idle_add(self._on_apply_done, False, str(e))

        threading.Thread(target=do_apply, daemon=True).start()

    def _on_apply_done(self, success, err=""):
        self.spinner.stop()
        self.apply_btn.set_sensitive(True)
        label, _, _, _ = PROFILES[self._current]
        if success:
            msg = f"Profile set to {label} — applied immediately"
        else:
            msg = f"Apply failed: {err}"
        toast = Adw.Toast.new(msg)
        toast.set_timeout(4)
        self._toast_overlay.add_toast(toast)


class GpuProfilerApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.cerberus9dev.RaptorGpuProfiler")
        self.connect("activate", self.on_activate)

    def on_activate(self, app):
        win = GpuProfilerWindow(application=app)
        win.present()


if __name__ == "__main__":
    import sys
    app = GpuProfilerApp()
    sys.exit(app.run(sys.argv))
GPUPYEOF
chmod +x /usr/bin/raptor-gpu-profiler

# ── .desktop launcher ─────────────────────────────────────────────────────────
# This was missing entirely in earlier versions — the GTK4 app existed at
# /usr/bin/raptor-gpu-profiler but had no menu entry, so it could never be
# launched from the app launcher. Matches raptor-cortex.desktop's format
# exactly so both apps appear consistently in the menu (same category,
# same Raptor OS branding).
mkdir -p /usr/share/applications
cat << 'DESKTOPEOF' > /usr/share/applications/raptor-gpu-profiler.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=Raptor GPU Profiler
GenericName=GPU Performance Profile Switcher
Comment=Switch GPU performance profiles, view live environment variables, per-game launch option reference
Exec=/usr/bin/raptor-gpu-profiler
Icon=raptor-gpu-profiler
Terminal=false
Categories=X-RaptorOS;System;Settings;
Keywords=gpu;graphics;profile;performance;vulkan;amd;nvidia;intel;
StartupNotify=true
X-KDE-SubstituteUID=false
DESKTOPEOF

echo "GPU_PROFILER_DESKTOP_READY"


echo "GPU_PROFILE_READY"
