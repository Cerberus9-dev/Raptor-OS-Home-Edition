#!/bin/bash
set -euo pipefail

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
         /etc/raptor

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

# ── Gaming sysctl: only retain broadly compatible limits ─────────────────────
# Memory policy belongs to raptor-gaming.conf / Raptor Cortex. Avoid hard-coded
# scheduler granularity and disabling split-lock mitigation on every CPU.
cat << 'SYSCTL' > /etc/sysctl.d/raptor-gaming.conf
kernel.sched_autogroup_enabled=1
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=256
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

# Read driver-advertised Intel bounds; never guess fixed clock frequencies.
_set_intel_gpu_power_mode() {
    local mode="$1" card rpmin rpmax
    for card in /sys/class/drm/card*/; do
        [ -d "$card" ] || continue
        [ -w "${card}gt_min_freq_mhz" ] && [ -w "${card}gt_max_freq_mhz" ] || continue
        rpmin=$(cat "${card}gt_RPn_freq_mhz" 2>/dev/null || true)
        rpmax=$(cat "${card}gt_RP0_freq_mhz" 2>/dev/null || true)
        [[ "$rpmin" =~ ^[0-9]+$ && "$rpmax" =~ ^[0-9]+$ ]] || continue
        echo "$rpmax" > "${card}gt_max_freq_mhz" 2>/dev/null || true
        echo "$rpmin" > "${card}gt_min_freq_mhz" 2>/dev/null || true
        if [ "$mode" = "powersave" ]; then
            echo "$rpmin" > "${card}gt_max_freq_mhz" 2>/dev/null || true
        fi
    done
}

# AMD profile indexes vary by driver/GPU. Resolve names from the driver's
# advertised profile table instead of assuming that index 1 or 2 is universal.
_set_amd_gpu_power_mode() {
    local dpm="$1" profile="$2" f id
    for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        [ -w "$f" ] && printf '%s\n' "$dpm" > "$f" 2>/dev/null || true
    done
    for f in /sys/class/drm/card*/device/pp_power_profile_mode; do
        [ -w "$f" ] || continue
        id=$(awk -v wanted="$profile" '
            NR > 1 {
                name=$2
                sub(/\*$/, "", name)
                if (name == wanted) { print $1; exit }
            }
        ' "$f" 2>/dev/null)
        [[ "$id" =~ ^[0-9]+$ ]] && printf '%s\n' "$id" > "$f" 2>/dev/null || true
    done
}

# Restore each NVIDIA GPU's own firmware default, not a guessed wattage.
_restore_nvidia_power_limits() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    local index limit
    while IFS=',' read -r index limit; do
        index="${index//[[:space:]]/}"
        limit="${limit//[[:space:]]/}"
        [[ "$index" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        nvidia-smi -i "$index" -pl "${limit%.*}" >/dev/null 2>&1 || true
    done < <(nvidia-smi --query-gpu=index,power.default_limit --format=csv,noheader,nounits 2>/dev/null)
}

_set_nvidia_power_saving() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    local index limit target
    nvidia-smi -pm 0 >/dev/null 2>&1 || true
    while IFS=',' read -r index limit; do
        index="${index//[[:space:]]/}"
        limit="${limit//[[:space:]]/}"
        [[ "$index" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        target=$(awk -v value="$limit" 'BEGIN { printf "%d", value * 0.8 }')
        [ "$target" -gt 0 ] && nvidia-smi -i "$index" -pl "$target" >/dev/null 2>&1 || true
    done < <(nvidia-smi --query-gpu=index,power.default_limit --format=csv,noheader,nounits 2>/dev/null)
}

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
DXVK_FRAME_RATE=0
VKD3D_CONFIG=dxr11,dxr
VKD3D_FEATURE_LEVEL=12_2
$COMMON_VARS
ENVEOF
    [ "$GPU_VENDOR" = "amd" ] && _set_amd_gpu_power_mode high 3D_FULL_SCREEN
    [ "$GPU_VENDOR" = "intel" ] && _set_intel_gpu_power_mode performance
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        _restore_nvidia_power_limits
        nvidia-smi -pm 1 >/dev/null 2>&1 || true
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
VKD3D_CONFIG=dxr11
VKD3D_FEATURE_LEVEL=12_1
$COMMON_VARS
ENVEOF
    [ "$GPU_VENDOR" = "amd" ] && _set_amd_gpu_power_mode high 3D_FULL_SCREEN
    [ "$GPU_VENDOR" = "intel" ] && _set_intel_gpu_power_mode performance
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        _restore_nvidia_power_limits
        nvidia-smi -pm 1 >/dev/null 2>&1 || true
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
    [ "$GPU_VENDOR" = "amd" ] && _set_amd_gpu_power_mode auto BOOTUP_DEFAULT
    [ "$GPU_VENDOR" = "intel" ] && _set_intel_gpu_power_mode balanced
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        _restore_nvidia_power_limits
        nvidia-smi -pm 0 >/dev/null 2>&1 || true
    fi
    ;;

  powersave)
    cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: POWER SAVING profile ──────────────────────────────────────────
MESA_SHADER_CACHE_DISABLE=false
__GL_THREADED_OPTIMIZATIONS=0
$COMMON_VARS
ENVEOF
    [ "$GPU_VENDOR" = "amd" ] && _set_amd_gpu_power_mode low POWER_SAVING
    if [ "$GPU_VENDOR" = "amd" ]; then
        for f in /sys/kernel/debug/dri/*/amdgpu_gfxoff; do
            [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || true
        done
    fi
    if [ "$GPU_VENDOR" = "intel" ]; then
        _set_intel_gpu_power_mode powersave
        echo 1 > /sys/module/i915/parameters/enable_psr 2>/dev/null || true
    fi
    [ "$GPU_VENDOR" = "nvidia" ] && _set_nvidia_power_saving
    ;;

  auto|*)
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: NVIDIA auto profile ────────────────────────────────────────────
__GL_SHADER_DISK_CACHE=1
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
__GL_THREADED_OPTIMIZATIONS=1
PROTON_ENABLE_NVAPI=1
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
$COMMON_VARS
ENVEOF
    elif [ "$GPU_VENDOR" = "intel" ]; then
        cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: Intel auto profile ─────────────────────────────────────────────
MESA_LOADER_DRIVER_OVERRIDE=iris
LIBGL_DRI3_DISABLE=0
$COMMON_VARS
ENVEOF
    else
        cat << ENVEOF > /etc/environment.d/raptor-gpu.conf
# ── Raptor OS: fallback profile ───────────────────────────────────────────────
MESA_SHADER_CACHE_DISABLE=false
$COMMON_VARS
ENVEOF
    fi
    [ "$GPU_VENDOR" = "amd" ] && _set_amd_gpu_power_mode auto BOOTUP_DEFAULT
    [ "$GPU_VENDOR" = "intel" ] && _set_intel_gpu_power_mode balanced
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        _restore_nvidia_power_limits
        nvidia-smi -pm 0 >/dev/null 2>&1 || true
    fi
    ;;
esac

# CPU policy is managed exclusively by power-profiles-daemon so KDE's
# battery slider remains authoritative. GPU profile changes must not write CPU policy.

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
   <!-- Wine/Proton: opt in to threaded GL where supported. Keep native
        applications on driver defaults for maximum compatibility. -->
   <application name="Wine" executable="wine">
      <option name="mesa_glthread" value="true" />
   </application>
   <application name="Wine64" executable="wine64">
      <option name="mesa_glthread" value="true" />
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
# Lets the desktop prompt once instead of asking for a password every time a
# profile is switched from Raptor Cortex. Only gpu-detect.sh is matched: the
# touch/rm of the marker files are already covered by the sudoers drop-in below.
cat << 'POLKIT' > /etc/polkit-1/rules.d/49-raptor-gpu.rules
polkit.addRule(function(action, subject) {
    var allowedActions = ["org.freedesktop.policykit.exec"];
    if (allowedActions.indexOf(action.id) >= 0 &&
        action.lookup("program") &&
        action.lookup("program").indexOf("gpu-detect.sh") !== -1 &&
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



# ── Self-check ────────────────────────────────────────────────────────────────
# A malformed heredoc here can install a truncated gpu-detect.sh, and the
# profile then silently never applies, with an empty build log.
# Verify each artifact landed and is non-empty; fail the build if not.
#
# The GTK UI that used to ship here is gone. GPU profile selection now lives in
# Raptor Cortex, so this package ships only the profile machinery it drives.
RAPTOR_EXPECTED_PAYLOAD="
/usr/lib/raptor/gpu-detect.sh
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "GPU_PROFILE_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
echo "GPU_PROFILE_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
