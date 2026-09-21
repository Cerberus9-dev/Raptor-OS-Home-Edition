#!/bin/bash
set -e

# =============================================================================
# Raptor HUD — F-22 Themed KDE Plasma Shell
# • RaptorOS color scheme (gunmetal + electric blue + amber)
# • Cockpit radar bottom taskbar
# • Working "Raptor OS" app-launcher category
# • GPU profiler TUI (detect, profile switch, crash handler toggle)
# • KDE crash handler (drkonqi) suppressed by default
# • Papirus-Dark icon theme  •  Aurorae window decoration
# • Applied at first login via systemd user unit
# =============================================================================

# ── Palette ───────────────────────────────────────────────────────────────────
# Base:    #0d0f12   Surface: #151a20   Panel:   #1c2330   Border:  #2a3444
# Accent:  #1e90ff   Warning: #f5a623   Success: #2ec27e   Text:    #c8d6e8

mkdir -p /usr/lib/raptor/hud \
         /usr/lib/raptor \
         /usr/lib/systemd/user \
         /usr/lib/systemd/system \
         /usr/bin \
         /usr/share/color-schemes \
         /usr/share/aurorae/themes/RaptorOS \
         /usr/share/desktop-directories \
         /usr/share/applications \
         /usr/share/konsole \
         /usr/share/themes/RaptorOS-GTK/gtk-3.0 \
         /usr/share/themes/RaptorOS-GTK/gtk-4.0 \
         /usr/share/Kvantum/RaptorOS \
         /etc/xdg/menus \
         /etc/xdg \
         /etc/environment.d \
         /etc/sysctl.d \
         /etc/polkit-1/rules.d \
         /etc/sudoers.d \
         /etc/raptor

# ══════════════════════════════════════════════════════════════════════════════
# KDE COLOR SCHEME
# ══════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > /usr/share/color-schemes/RaptorOS.colors
[ColorEffects:Disabled]
Color=56,68,82
ColorAmount=0.55
ColorEffect=3
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=0.1
IntensityEffect=2

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color=56,68,82
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0

[Colors:Button]
BackgroundAlternate=30,42,58
BackgroundNormal=28,35,48
DecorationFocus=30,144,255
DecorationHover=30,144,255
ForegroundActive=30,144,255
ForegroundInactive=90,106,126
ForegroundLink=30,144,255
ForegroundNegative=220,50,50
ForegroundNeutral=245,166,35
ForegroundNormal=200,214,232
ForegroundPositive=46,194,126
ForegroundVisited=140,100,220

[Colors:Complementary]
BackgroundAlternate=20,28,40
BackgroundNormal=13,15,18
DecorationFocus=30,144,255
DecorationHover=30,144,255
ForegroundActive=30,144,255
ForegroundInactive=90,106,126
ForegroundLink=30,144,255
ForegroundNegative=220,50,50
ForegroundNeutral=245,166,35
ForegroundNormal=200,214,232
ForegroundPositive=46,194,126
ForegroundVisited=140,100,220

[Colors:Header]
BackgroundAlternate=21,26,32
BackgroundNormal=21,26,32
DecorationFocus=30,144,255
DecorationHover=30,144,255
ForegroundActive=30,144,255
ForegroundInactive=90,106,126
ForegroundLink=30,144,255
ForegroundNegative=220,50,50
ForegroundNeutral=245,166,35
ForegroundNormal=200,214,232
ForegroundPositive=46,194,126
ForegroundVisited=140,100,220

[Colors:Selection]
BackgroundAlternate=20,100,200
BackgroundNormal=30,144,255
DecorationFocus=30,144,255
DecorationHover=30,144,255
ForegroundActive=255,255,255
ForegroundInactive=180,200,220
ForegroundLink=180,220,255
ForegroundNegative=220,50,50
ForegroundNeutral=245,166,35
ForegroundNormal=255,255,255
ForegroundPositive=46,194,126
ForegroundVisited=200,170,255

[Colors:Tooltip]
BackgroundAlternate=21,26,32
BackgroundNormal=13,15,18
DecorationFocus=30,144,255
DecorationHover=30,144,255
ForegroundActive=30,144,255
ForegroundInactive=90,106,126
ForegroundLink=30,144,255
ForegroundNegative=220,50,50
ForegroundNeutral=245,166,35
ForegroundNormal=200,214,232
ForegroundPositive=46,194,126
ForegroundVisited=140,100,220

[Colors:View]
BackgroundAlternate=18,24,32
BackgroundNormal=13,15,18
DecorationFocus=30,144,255
DecorationHover=30,144,255
ForegroundActive=30,144,255
ForegroundInactive=90,106,126
ForegroundLink=30,144,255
ForegroundNegative=220,50,50
ForegroundNeutral=245,166,35
ForegroundNormal=200,214,232
ForegroundPositive=46,194,126
ForegroundVisited=140,100,220

[Colors:Window]
BackgroundAlternate=21,26,32
BackgroundNormal=28,35,48
DecorationFocus=30,144,255
DecorationHover=30,144,255
ForegroundActive=30,144,255
ForegroundInactive=90,106,126
ForegroundLink=30,144,255
ForegroundNegative=220,50,50
ForegroundNeutral=245,166,35
ForegroundNormal=200,214,232
ForegroundPositive=46,194,126
ForegroundVisited=140,100,220

[General]
ColorScheme=RaptorOS
Name=RaptorOS
shadeSortColumn=true

[KDE]
contrast=5

[WM]
activeBackground=21,26,32
activeBlend=30,144,255
activeForeground=200,214,232
inactiveBackground=13,15,18
inactiveBlend=42,52,68
inactiveForeground=90,106,126
EOF

# ══════════════════════════════════════════════════════════════════════════════
# AURORAE WINDOW DECORATION
# ══════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > /usr/share/aurorae/themes/RaptorOS/RaptorOSrc
[General]
ActiveTextColor=200,214,232
Animation=0
BorderBottom=1
BorderLeft=1
BorderRight=1
BorderTop=0
ButtonHeight=18
ButtonMarginTop=6
ButtonSpacing=2
ButtonWidth=18
DecorationPosition=0
DrawButtons=true
DrawSeparator=false
GrabBarBelow=false
InactiveTextColor=90,106,126
OverrideBorderSizes=false
PaddingBottom=4
PaddingLeft=4
PaddingRight=4
PaddingTop=0
ShadowColor=0,0,0
ShadowOpacity=0.8
ShadowSize=30
TitleAlignment=1
TitleEdgeBottom=4
TitleEdgeLeft=6
TitleEdgeRight=6
TitleEdgeTop=6
TitleHeight=24
UseKWinTextColors=true
EOF

cat << 'SVGEOF' > /usr/share/aurorae/themes/RaptorOS/RaptorOS.svg
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
  <defs>
    <linearGradient id="titlebar-active" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#1c2330"/>
      <stop offset="100%" stop-color="#151a20"/>
    </linearGradient>
    <linearGradient id="titlebar-inactive" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#111418"/>
      <stop offset="100%" stop-color="#0d0f12"/>
    </linearGradient>
  </defs>
  <g id="decoration">
    <rect width="100" height="30" fill="url(#titlebar-active)"/>
    <rect y="29" width="100" height="1" fill="#1e90ff" opacity="0.7"/>
    <rect width="2" height="30" fill="#1e90ff" opacity="0.5"/>
  </g>
  <g id="decoration-inactive">
    <rect width="100" height="30" fill="url(#titlebar-inactive)"/>
    <rect y="29" width="100" height="1" fill="#2a3444"/>
    <rect width="2" height="30" fill="#2a3444"/>
  </g>
  <g id="close">
    <rect width="18" height="18" rx="1" fill="#3a1515"/>
    <line x1="5" y1="5" x2="13" y2="13" stroke="#cc3333" stroke-width="1.5" stroke-linecap="square"/>
    <line x1="13" y1="5" x2="5" y2="13" stroke="#cc3333" stroke-width="1.5" stroke-linecap="square"/>
  </g>
  <g id="close-hover">
    <rect width="18" height="18" rx="1" fill="#cc3333"/>
    <line x1="5" y1="5" x2="13" y2="13" stroke="white" stroke-width="1.5" stroke-linecap="square"/>
    <line x1="13" y1="5" x2="5" y2="13" stroke="white" stroke-width="1.5" stroke-linecap="square"/>
  </g>
  <g id="maximize">
    <rect width="18" height="18" rx="1" fill="#1c2330"/>
    <rect x="4" y="4" width="10" height="10" fill="none" stroke="#1e90ff" stroke-width="1.5"/>
  </g>
  <g id="maximize-hover">
    <rect width="18" height="18" rx="1" fill="#1e4a7a"/>
    <rect x="4" y="4" width="10" height="10" fill="none" stroke="#5ab0ff" stroke-width="1.5"/>
  </g>
  <g id="minimize">
    <rect width="18" height="18" rx="1" fill="#1c2330"/>
    <line x1="4" y1="13" x2="14" y2="13" stroke="#1e90ff" stroke-width="1.5" stroke-linecap="square"/>
  </g>
  <g id="minimize-hover">
    <rect width="18" height="18" rx="1" fill="#1e4a7a"/>
    <line x1="4" y1="13" x2="14" y2="13" stroke="#5ab0ff" stroke-width="1.5" stroke-linecap="square"/>
  </g>
</svg>
SVGEOF

# ══════════════════════════════════════════════════════════════════════════════
# APP LAUNCHER CATEGORY
# ══════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > /usr/share/desktop-directories/raptor-os.directory
[Desktop Entry]
Type=Directory
Name=Raptor OS
Comment=Raptor OS tools and utilities
Icon=computer
EOF

# Drop a single merge file into applications-merged/ — this is the correct way
# to ADD a category without touching or replacing the system menu file.
# The system's plasma-applications.menu includes <DefaultMergeDirs/> which
# reads every .menu file from applications-merged/ automatically.
# Writing to plasma-applications.menu directly replaces the whole menu (which
# is why every other category was disappearing).
mkdir -p /etc/xdg/menus/applications-merged

cat << 'MENUEOF' > /etc/xdg/menus/applications-merged/raptor-os.menu
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
  "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
<Menu>
  <Name>Applications</Name>
  <Menu>
    <Name>Raptor OS</Name>
    <Directory>raptor-os.directory</Directory>
    <Include>
      <Category>X-RaptorOS</Category>
    </Include>
  </Menu>
</Menu>
MENUEOF

# ══════════════════════════════════════════════════════════════════════════════
# GPU PROFILE DETECTION  (boot service)
# ══════════════════════════════════════════════════════════════════════════════
cat << 'ENVEOF' > /etc/environment.d/raptor-gpu.conf
# Raptor OS: GPU profile — safe build-time fallback; replaced on first boot.
MESA_SHADER_CACHE_DISABLE=false
WINE_LARGE_ADDRESS_AWARE=1
PROTON_FORCE_LARGE_ADDRESS_AWARE=1
STAGING_SHARED_MEMORY=1
WINE_FULLSCREEN_FSR=1
PROTON_NO_ESYNC=0
PROTON_NO_FSYNC=0
ENVEOF

cat << 'SYSCTL' > /etc/sysctl.d/raptor-gaming.conf
kernel.sched_autogroup_enabled=1
kernel.sched_min_granularity_ns=500000
kernel.sched_wakeup_granularity_ns=3000000
kernel.sched_migration_cost_ns=250000
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=256
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
kernel.split_lock_mitigate=0
SYSCTL

cat << 'DETECT' > /usr/lib/raptor/gpu-detect.sh
#!/bin/bash
set -euo pipefail
LOG_TAG="raptor-gpu"
log() { echo "$*"; logger -t "$LOG_TAG" "$*" 2>/dev/null || true; }

LSPCI_OUT=$(lspci 2>/dev/null | grep -iE "VGA|3D controller|Display controller" || true)
GPU_VENDOR="unknown"; GPU_MODEL=""

if   echo "$LSPCI_OUT" | grep -qi "nvidia";           then GPU_VENDOR="nvidia"
    GPU_MODEL=$(echo "$LSPCI_OUT" | grep -i nvidia              | head -1 | sed 's/.*: //')
elif echo "$LSPCI_OUT" | grep -qiE "amd|radeon|ati";  then GPU_VENDOR="amd"
    GPU_MODEL=$(echo "$LSPCI_OUT" | grep -iE "amd|radeon|ati"  | head -1 | sed 's/.*: //')
elif echo "$LSPCI_OUT" | grep -qi "intel";             then GPU_VENDOR="intel"
    GPU_MODEL=$(echo "$LSPCI_OUT" | grep -i intel               | head -1 | sed 's/.*: //')
fi
log "GPU vendor=$GPU_VENDOR model=${GPU_MODEL:-unknown}"

IS_IGPU=false
if echo "$LSPCI_OUT" | grep -qi "intel"; then
    lsmod 2>/dev/null | grep -qiE "^nvidia |^amdgpu " || IS_IGPU=true
elif [ "$GPU_VENDOR" = "amd" ]; then
    VRAM=$(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null || echo 0)
    [ "$VRAM" -lt $((512*1024*1024)) ] && IS_IGPU=true || true
fi

IS_HYBRID=false
DISPLAY_DEVS=$(echo "$LSPCI_OUT" | grep -c "" || true)
[ "$DISPLAY_DEVS" -ge 2 ] && IS_HYBRID=true
DRM_CARDS=$(ls /sys/class/drm/ 2>/dev/null | grep -c "^card[0-9]$" || echo 0)
[ "$DRM_CARDS" -ge 2 ] && IS_HYBRID=true

PROFILE="auto"
[ -f /etc/raptor-force-extreme ]     && PROFILE="extreme"
[ -f /etc/raptor-force-performance ] && PROFILE="performance"
[ -f /etc/raptor-force-powersave ]   && PROFILE="powersave"
[ -f /etc/raptor-force-balanced ]    && PROFILE="balanced"
log "profile=$PROFILE"

COMMON_VARS="WINE_LARGE_ADDRESS_AWARE=1
PROTON_FORCE_LARGE_ADDRESS_AWARE=1
STAGING_SHARED_MEMORY=1
WINE_FULLSCREEN_FSR=1
PROTON_NO_ESYNC=0
PROTON_NO_FSYNC=0"

write_env() {
    local COMMENT="$1"; shift
    { echo "# ── Raptor OS: $COMMENT ──"; printf '%s\n' "$@"; } \
        > /etc/environment.d/raptor-gpu.conf
}

case "$PROFILE" in
  extreme)
    write_env "EXTREME PERFORMANCE profile" \
        "AMD_VULKAN_ICD=RADV" "MESA_SHADER_CACHE_DISABLE=false" \
        "MESA_SHADER_CACHE_MAX_SIZE=4G" "__GL_SHADER_DISK_CACHE=1" \
        "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1" "__GL_THREADED_OPTIMIZATIONS=1" \
        "AMDGPU_HIGH_POWER=1" "PROTON_ENABLE_NVAPI=1" "DXVK_ASYNC=1" \
        "DXVK_FRAME_RATE=0" "RADV_DEBUG=nocompute" \
        "VKD3D_CONFIG=dxr11,dxr" "VKD3D_FEATURE_LEVEL=12_2" $COMMON_VARS
    if [ "$GPU_VENDOR" = "amd" ]; then
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do echo "high" > "$f" 2>/dev/null || true; done
        for f in /sys/class/drm/card*/device/pp_power_profile_mode; do echo 1 > "$f" 2>/dev/null || true; done
    fi
    [ "$GPU_VENDOR" = "nvidia" ] && { nvidia-smi -pm 1 >/dev/null 2>&1 || true; nvidia-smi --auto-boost-default=0 >/dev/null 2>&1 || true; }
    ;;
  performance)
    write_env "MAX PERFORMANCE profile" \
        "AMD_VULKAN_ICD=RADV" "MESA_SHADER_CACHE_DISABLE=false" \
        "MESA_SHADER_CACHE_MAX_SIZE=2G" "__GL_SHADER_DISK_CACHE=1" \
        "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1" "__GL_THREADED_OPTIMIZATIONS=1" \
        "PROTON_ENABLE_NVAPI=1" "DXVK_ASYNC=1" \
        "VKD3D_CONFIG=dxr11" "VKD3D_FEATURE_LEVEL=12_1" $COMMON_VARS
    if [ "$GPU_VENDOR" = "amd" ]; then
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do echo "high" > "$f" 2>/dev/null || true; done
    fi
    [ "$GPU_VENDOR" = "nvidia" ] && { nvidia-smi -pm 1 >/dev/null 2>&1 || true; }
    ;;
  balanced)
    write_env "BALANCED profile" \
        "AMD_VULKAN_ICD=RADV" "MESA_SHADER_CACHE_DISABLE=false" \
        "__GL_SHADER_DISK_CACHE=1" "PROTON_ENABLE_NVAPI=1" $COMMON_VARS
    if [ "$GPU_VENDOR" = "amd" ]; then
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do echo "auto" > "$f" 2>/dev/null || true; done
    fi
    ;;
  powersave)
    write_env "POWER SAVING profile" "MESA_SHADER_CACHE_DISABLE=true" $COMMON_VARS
    if [ "$GPU_VENDOR" = "amd" ]; then
        for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do echo "low" > "$f" 2>/dev/null || true; done
    fi
    [ "$GPU_VENDOR" = "nvidia" ] && { nvidia-smi -pm 0 >/dev/null 2>&1 || true; }
    ;;
  auto|*)
    if [ "$GPU_VENDOR" = "nvidia" ]; then
        write_env "NVIDIA auto profile" \
            "__GL_SHADER_DISK_CACHE=1" "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1" \
            "__GL_THREADED_OPTIMIZATIONS=1" "PROTON_ENABLE_NVAPI=1" \
            "DXVK_ASYNC=1" "VKD3D_CONFIG=dxr11" $COMMON_VARS
    elif [ "$GPU_VENDOR" = "amd" ] && [ "$IS_IGPU" = true ]; then
        write_env "AMD iGPU auto profile" \
            "AMD_VULKAN_ICD=RADV" "MESA_SHADER_CACHE_DISABLE=false" $COMMON_VARS
    elif [ "$GPU_VENDOR" = "amd" ]; then
        write_env "AMD dGPU auto profile" \
            "AMD_VULKAN_ICD=RADV" "MESA_SHADER_CACHE_DISABLE=false" \
            "MESA_SHADER_CACHE_MAX_SIZE=2G" "__GL_SHADER_DISK_CACHE=1" \
            "DXVK_ASYNC=1" $COMMON_VARS
    elif [ "$GPU_VENDOR" = "intel" ]; then
        write_env "Intel auto profile" \
            "MESA_LOADER_DRIVER_OVERRIDE=iris" "LIBGL_DRI3_DISABLE=0" \
            "vblank_mode=0" $COMMON_VARS
    else
        write_env "fallback profile" "MESA_SHADER_CACHE_DISABLE=false" $COMMON_VARS
    fi
    ;;
esac

set_cpu_governor() {
    ls /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor &>/dev/null || { log "cpufreq not available"; return; }
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$1" > "$f" 2>/dev/null || true; done
    log "CPU governor → $1"
}
case "$PROFILE" in
    extreme|performance) set_cpu_governor "performance" ;;
    balanced)            set_cpu_governor "schedutil"   ;;
    powersave)           set_cpu_governor "powersave"   ;;
    auto|*)              set_cpu_governor "schedutil"   ;;
esac

ENVFILE=/etc/environment.d/raptor-gpu.conf
if [ -f "$ENVFILE" ]; then
    ENV_KEYS=()
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue; [[ -z "$line" ]] && continue
        ENV_KEYS+=("${line%%=*}")
    done < "$ENVFILE"
    if [ ${#ENV_KEYS[@]} -gt 0 ]; then
        set -a; source "$ENVFILE"; set +a
        while read -r UID_VAL _REST; do
            [[ "$UID_VAL" =~ ^[0-9]+$ ]] || continue
            RUNTIME_DIR="/run/user/$UID_VAL"; [ -d "$RUNTIME_DIR" ] || continue
            sudo -u "#$UID_VAL" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
                systemctl --user import-environment "${ENV_KEYS[@]}" 2>/dev/null || true
            USER_HOME=$(getent passwd "$UID_VAL" | cut -d: -f6)
            mkdir -p "$USER_HOME/.config/environment.d" 2>/dev/null || true
            cp "$ENVFILE" "$USER_HOME/.config/environment.d/raptor-gpu.conf" 2>/dev/null || true
        done < <(loginctl list-users --no-legend 2>/dev/null || true)
    fi
fi

sysctl --system >/dev/null 2>&1 || true
log "GPU_PROFILE_READY profile=$PROFILE vendor=$GPU_VENDOR igpu=$IS_IGPU hybrid=$IS_HYBRID"
DETECT
chmod +x /usr/lib/raptor/gpu-detect.sh

cat << 'SVCEOF' > /usr/lib/systemd/system/raptor-gpu-profile.service
[Unit]
Description=Raptor OS — GPU Profile Detection & Configuration
After=sysinit.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/lib/raptor/gpu-detect.sh
RemainAfterExit=yes
SuccessExitStatus=0 1

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable raptor-gpu-profile.service 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# KDE CRASH HANDLER SUPPRESSION  (drkonqi)
# Default: disabled system-wide via /etc/xdg/kcrashrc + user service
# The GPU profiler TUI exposes a toggle to re-enable it per-user.
# ══════════════════════════════════════════════════════════════════════════════

# System-wide default — KCrash reads this before any service starts
printf '[drkonqi]\nAlwaysDirectly=true\n' > /etc/xdg/kcrashrc

# Seed Cortex persistent config with the default
echo "drkonqi_disabled=true" > /etc/raptor/cortex-defaults.conf

# Per-user apply script (no root needed — runs as the logged-in user)
cat << 'EOF' > /usr/lib/raptor/drkonqi-apply.sh
#!/bin/bash
set -euo pipefail
KCRASH="${HOME}/.config/kcrashrc"
USER_CFG="${HOME}/.config/raptor-cortex.conf"
SYS_CFG="/etc/raptor/cortex-defaults.conf"

read_key() { grep -m1 "^${1}=" "$2" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true; }
VAL=$(read_key drkonqi_disabled "$USER_CFG")
[ -z "$VAL" ] && VAL=$(read_key drkonqi_disabled "$SYS_CFG")

if [ "$VAL" != "false" ]; then
    systemctl --user mask --now drkonqi.service drkonqi 2>/dev/null || true
    mkdir -p "$(dirname "$KCRASH")"
    grep -q 'AlwaysDirectly' "$KCRASH" 2>/dev/null || \
        printf '[drkonqi]\nAlwaysDirectly=true\n' >> "$KCRASH"
else
    systemctl --user unmask drkonqi.service drkonqi 2>/dev/null || true
    sed -i '/AlwaysDirectly/d' "$KCRASH" 2>/dev/null || true
fi
EOF
chmod +x /usr/lib/raptor/drkonqi-apply.sh

# User service — re-applies on every login (survives KDE updates)
cat << 'EOF' > /usr/lib/systemd/user/raptor-drkonqi.service
[Unit]
Description=Raptor OS — KDE Crash Handler preference
ConditionPathExists=/etc/raptor/cortex-defaults.conf
After=plasma-plasmashell.service

[Service]
Type=oneshot
ExecStart=/usr/lib/raptor/drkonqi-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=plasma-plasmashell.service
EOF
systemctl --global enable raptor-drkonqi.service 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# GPU PROFILER TUI  (includes crash handler toggle)
# ══════════════════════════════════════════════════════════════════════════════
cat << 'UIEOF' > /usr/bin/raptor-gpu-profile-ui.sh
#!/bin/bash
DETECT_SCRIPT="/usr/lib/raptor/gpu-detect.sh"
ENV_FILE="/etc/environment.d/raptor-gpu.conf"
FORCE_DIR="/etc"
USER_CFG="${HOME}/.config/raptor-cortex.conf"
SYS_CFG="/etc/raptor/cortex-defaults.conf"

R='\033[0m'; BLUE='\033[38;5;33m'; AMBER='\033[38;5;214m'
GREEN='\033[38;5;42m'; DIM='\033[38;5;60m'; BOLD='\033[1m'; RED='\033[38;5;160m'

current_profile() {
    for p in extreme performance balanced powersave; do
        [ -f "$FORCE_DIR/raptor-force-$p" ] && { echo "$p"; return; }
    done; echo "auto"
}
read_conf_key() { grep -m1 "^${1}=" "$2" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true; }
drkonqi_disabled() {
    local v; v=$(read_conf_key drkonqi_disabled "$USER_CFG")
    [ -z "$v" ] && v=$(read_conf_key drkonqi_disabled "$SYS_CFG")
    [ "$v" != "false" ] && echo "true" || echo "false"
}
write_user_key() {
    local KEY="$1" VAL="$2"
    mkdir -p "$(dirname "$USER_CFG")"
    local tmp; tmp=$(mktemp)
    grep -v "^${KEY}=" "$USER_CFG" 2>/dev/null > "$tmp" || true
    echo "${KEY}=${VAL}" >> "$tmp"
    mv "$tmp" "$USER_CFG"
}

read_gpu_model()  { lspci 2>/dev/null | grep -iE "VGA|3D|Display" | head -1 | sed 's/.*: //' | cut -c1-56 || echo "Unknown GPU"; }
read_gpu_vendor() {
    local l; l=$(lspci 2>/dev/null | grep -iE "VGA|3D|Display" | head -1 || true)
    if   echo "$l" | grep -qi nvidia;        then echo "NVIDIA"
    elif echo "$l" | grep -qiE "amd|radeon"; then echo "AMD"
    elif echo "$l" | grep -qi intel;         then echo "Intel"
    else echo "Unknown"; fi
}
read_vram() {
    local v; v=$(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null || true)
    [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && { echo "$(( v/1024/1024 )) MiB"; return; }
    v=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    [ -n "$v" ] && { echo "${v} MiB"; return; }; echo "N/A"
}
read_gpu_temp() {
    local t; t=$(cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input 2>/dev/null | head -1 || true)
    [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null && { echo "$(( t/1000 ))°C"; return; }
    t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 || true)
    [ -n "$t" ] && { echo "${t}°C"; return; }; echo "N/A"
}
read_gpu_util() {
    local u; u=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
    [ -n "$u" ] && { echo "${u}%"; return; }
    u=$(cat /sys/class/drm/card0/device/gpu_busy_percent 2>/dev/null || true)
    [ -n "$u" ] && { echo "${u}%"; return; }; echo "N/A"
}

draw_header() {
    clear
    echo -e "${BLUE}${BOLD}"
    echo "  ██████╗  █████╗ ██████╗ ████████╗ ██████╗ ██████╗      ██████╗ ███████╗"
    echo "  ██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗    ██╔═══██╗██╔════╝"
    echo "  ██████╔╝███████║██████╔╝   ██║   ██║   ██║██████╔╝    ██║   ██║███████╗"
    echo "  ██╔══██╗██╔══██║██╔═══╝    ██║   ██║   ██║██╔══██╗    ██║   ██║╚════██║"
    echo "  ██║  ██║██║  ██║██║        ██║   ╚██████╔╝██║  ██║    ╚██████╔╝███████║"
    echo "  ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝        ╚═╝    ╚═════╝ ╚═╝  ╚═╝     ╚═════╝ ╚══════╝"
    echo -e "${R}"
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo -e "  ${AMBER}▸ GPU PROFILER  ${DIM}│${R}  F-22 RAPTOR HUD  ${DIM}│${R}  $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo ""
}

draw_status() {
    local PROF; PROF=$(current_profile)
    local CRASH; CRASH=$(drkonqi_disabled)
    echo -e "  ${BOLD}HARDWARE${R}"
    echo -e "  ${DIM}┌─────────────────────────────────────────────────┐${R}"
    printf   "  ${DIM}│${R}  Vendor   ${BLUE}%-38s${R}${DIM}│${R}\n" "$(read_gpu_vendor)"
    printf   "  ${DIM}│${R}  Model    ${BLUE}%-38s${R}${DIM}│${R}\n" "$(read_gpu_model)"
    printf   "  ${DIM}│${R}  VRAM     ${BLUE}%-38s${R}${DIM}│${R}\n" "$(read_vram)"
    echo -e  "  ${DIM}└─────────────────────────────────────────────────┘${R}"
    echo ""
    echo -e "  ${BOLD}LIVE TELEMETRY${R}"
    echo -e "  ${DIM}┌─────────────────────────────────────────────────┐${R}"
    printf   "  ${DIM}│${R}  Temp     ${AMBER}%-38s${R}${DIM}│${R}\n" "$(read_gpu_temp)"
    printf   "  ${DIM}│${R}  Usage    ${GREEN}%-38s${R}${DIM}│${R}\n" "$(read_gpu_util)"
    printf   "  ${DIM}│${R}  Profile  "
    case "$PROF" in
        extreme)     printf "${RED}%-38s${R}"   "■ EXTREME"         ;;
        performance) printf "${AMBER}%-38s${R}" "▲ PERFORMANCE"     ;;
        balanced)    printf "${GREEN}%-38s${R}" "● BALANCED"        ;;
        powersave)   printf "${BLUE}%-38s${R}"  "▼ POWER SAVE"      ;;
        auto|*)      printf "${DIM}%-38s${R}"   "○ AUTO (detected)" ;;
    esac
    echo -e "${DIM}│${R}"
    printf   "  ${DIM}│${R}  Crash    "
    if [ "$CRASH" = "true" ]; then
        printf "${GREEN}%-38s${R}" "● SUPPRESSED (drkonqi off)"
    else
        printf "${DIM}%-38s${R}" "○ ENABLED (drkonqi on)"
    fi
    echo -e "${DIM}│${R}"
    echo -e "  ${DIM}└─────────────────────────────────────────────────┘${R}"
    echo ""
}

draw_menu() {
    local CRASH; CRASH=$(drkonqi_disabled)
    echo -e "  ${BOLD}SELECT PROFILE${R}"
    echo -e "  ${DIM}──────────────────────────────────────────────────${R}"
    echo -e "  ${RED}[1]${R}  ■  EXTREME     Max clocks, no power cap"
    echo -e "  ${AMBER}[2]${R}  ▲  PERFORMANCE High clocks, GPU persistence on"
    echo -e "  ${GREEN}[3]${R}  ●  BALANCED    Auto clocks, schedutil CPU"
    echo -e "  ${BLUE}[4]${R}  ▼  POWER SAVE  Low clocks, minimal draw"
    echo -e "  ${DIM}[5]${R}  ○  AUTO        Detect and apply best profile"
    echo -e "  ${DIM}──────────────────────────────────────────────────${R}"
    echo -e "  ${BOLD}ADVANCED${R}"
    echo -e "  ${DIM}──────────────────────────────────────────────────${R}"
    if [ "$CRASH" = "true" ]; then
        echo -e "  ${GREEN}[6]${R}  ●  Crash Handler   SUPPRESSED  (toggle to enable)"
    else
        echo -e "  ${DIM}[6]${R}  ○  Crash Handler   ENABLED     (toggle to suppress)"
    fi
    echo -e "  ${DIM}──────────────────────────────────────────────────${R}"
    echo -e "  ${DIM}[r]${R}  Refresh   ${DIM}[l]${R}  Show env vars   ${DIM}[q]${R}  Quit"
    echo ""
    echo -ne "  ${BLUE}RAPTOR>${R}  "
}

apply_profile() {
    local TARGET="$1"
    echo -e "\n  ${AMBER}Applying profile: ${BOLD}${TARGET}${R}"
    sudo rm -f \
        "$FORCE_DIR/raptor-force-extreme" \
        "$FORCE_DIR/raptor-force-performance" \
        "$FORCE_DIR/raptor-force-balanced" \
        "$FORCE_DIR/raptor-force-powersave" 2>/dev/null || true
    if [ "$TARGET" != "auto" ]; then
        sudo touch "$FORCE_DIR/raptor-force-$TARGET" 2>/dev/null || {
            echo -e "  ${RED}[ERROR]${R} Could not write flag — check sudoers."; sleep 2; return
        }
    fi
    echo -e "  ${DIM}Running gpu-detect.sh…${R}"
    sudo "$DETECT_SCRIPT" && \
        echo -e "  ${GREEN}[OK]${R} Profile applied. Open apps need restart for new env vars." || \
        echo -e "  ${RED}[WARN]${R} gpu-detect.sh exited non-zero."
    sleep 2
}

toggle_crash_handler() {
    local CURRENT; CURRENT=$(drkonqi_disabled)
    if [ "$CURRENT" = "true" ]; then
        write_user_key "drkonqi_disabled" "false"
        systemctl --user unmask drkonqi.service drkonqi 2>/dev/null || true
        local KCRASH="${HOME}/.config/kcrashrc"
        sed -i '/AlwaysDirectly/d' "$KCRASH" 2>/dev/null || true
        echo -e "\n  ${AMBER}[INFO]${R} Crash handler ENABLED — drkonqi will show on KDE app crashes."
    else
        write_user_key "drkonqi_disabled" "true"
        systemctl --user mask --now drkonqi.service drkonqi 2>/dev/null || true
        local KCRASH="${HOME}/.config/kcrashrc"
        mkdir -p "$(dirname "$KCRASH")"
        grep -q 'AlwaysDirectly' "$KCRASH" 2>/dev/null || \
            printf '[drkonqi]\nAlwaysDirectly=true\n' >> "$KCRASH"
        echo -e "\n  ${GREEN}[OK]${R} Crash handler SUPPRESSED — KDE app crashes will be silent."
    fi
    echo -e "  ${DIM}Setting persists across reboots via raptor-drkonqi.service${R}"
    sleep 2
}

show_env() {
    echo ""
    echo -e "  ${BOLD}CURRENT ENV  ${DIM}(${ENV_FILE})${R}"
    echo -e "  ${DIM}──────────────────────────────────────────────────${R}"
    if [ -f "$ENV_FILE" ]; then
        grep -v '^#' "$ENV_FILE" | grep -v '^$' | while IFS= read -r line; do
            printf "  ${BLUE}%-36s${R}${DIM}=${R}${AMBER}%s${R}\n" "${line%%=*}" "${line#*=}"
        done
    else
        echo -e "  ${DIM}(env file not found)${R}"
    fi
    echo ""; echo -ne "  ${DIM}Press Enter to return…${R}  "; read -r
}

while true; do
    draw_header; draw_status; draw_menu
    read -r -t 30 CHOICE || { echo ""; continue; }
    case "$CHOICE" in
        1) apply_profile "extreme"     ;;
        2) apply_profile "performance" ;;
        3) apply_profile "balanced"    ;;
        4) apply_profile "powersave"   ;;
        5) apply_profile "auto"        ;;
        6) toggle_crash_handler        ;;
        r|R) continue ;;
        l|L) draw_header; show_env ;;
        q|Q) echo -e "\n  ${DIM}Raptor GPU Profiler closed.${R}\n"; exit 0 ;;
        *) echo -e "  ${DIM}Unknown — use 1-6, r, l, q${R}"; sleep 1 ;;
    esac
done
UIEOF
chmod +x /usr/bin/raptor-gpu-profile-ui.sh

# Launcher — opens the TUI in best available terminal
cat << 'LAUNCHEOF' > /usr/bin/raptor-gpu-profile-launcher
#!/bin/bash
TUI="/usr/bin/raptor-gpu-profile-ui.sh"
TITLE="Raptor GPU Profiler"
if   command -v konsole   &>/dev/null; then konsole --title "$TITLE" --profile RaptorOS --noclose -e bash "$TUI"
elif command -v alacritty &>/dev/null; then alacritty --title "$TITLE" --config-file /dev/null -e bash "$TUI"
elif command -v kitty     &>/dev/null; then kitty --title "$TITLE" bash "$TUI"
elif command -v xterm     &>/dev/null; then xterm -title "$TITLE" -fa "JetBrains Mono" -fs 11 -bg "#0d0f12" -fg "#c8d6e8" -e bash "$TUI"
else bash "$TUI"; fi
LAUNCHEOF
chmod +x /usr/bin/raptor-gpu-profile-launcher

cat << 'POLKIT' > /etc/polkit-1/rules.d/49-raptor-gpu.rules
polkit.addRule(function(action, subject) {
    var allowedActions = ["org.freedesktop.policykit.exec"];
    if (allowedActions.indexOf(action.id) >= 0 &&
        action.lookup("program") &&
        action.lookup("program").indexOf("raptor") !== -1 &&
        subject.active && subject.local) {
        return polkit.Result.YES;
    }
});
POLKIT

cat << 'SUDOERS' > /etc/sudoers.d/raptor-gpu
ALL ALL=(root) NOPASSWD: /usr/lib/raptor/gpu-detect.sh
ALL ALL=(root) NOPASSWD: /usr/bin/touch /etc/raptor-force-extreme
ALL ALL=(root) NOPASSWD: /usr/bin/touch /etc/raptor-force-performance
ALL ALL=(root) NOPASSWD: /usr/bin/touch /etc/raptor-force-balanced
ALL ALL=(root) NOPASSWD: /usr/bin/touch /etc/raptor-force-powersave
ALL ALL=(root) NOPASSWD: /usr/bin/rm -f /etc/raptor-force-extreme
ALL ALL=(root) NOPASSWD: /usr/bin/rm -f /etc/raptor-force-performance
ALL ALL=(root) NOPASSWD: /usr/bin/rm -f /etc/raptor-force-balanced
ALL ALL=(root) NOPASSWD: /usr/bin/rm -f /etc/raptor-force-powersave
ALL ALL=(root) NOPASSWD: /usr/sbin/sysctl --system
SUDOERS
chmod 440 /etc/sudoers.d/raptor-gpu
command -v visudo &>/dev/null && visudo -c -f /etc/sudoers.d/raptor-gpu >/dev/null && echo "[OK] sudoers valid"

cat << 'EOF' > /usr/share/applications/raptor-gpu-profile.desktop
[Desktop Entry]
Type=Application
Name=Raptor GPU Profiler
GenericName=GPU Monitor
Comment=Monitor and manage GPU performance profiles
Exec=/usr/bin/raptor-gpu-profile-launcher
TryExec=/usr/bin/raptor-gpu-profile-launcher
Icon=preferences-system-performance
Terminal=false
NoDisplay=false
Categories=X-RaptorOS;
Keywords=gpu;profile;performance;raptor;
StartupNotify=true
EOF
command -v desktop-file-validate &>/dev/null && \
    desktop-file-validate /usr/share/applications/raptor-gpu-profile.desktop >/dev/null && echo "[OK] .desktop valid"

# ── No custom Plasma panel theme or radar plasmoid — KDE default taskbar ───────

# ══════════════════════════════════════════════════════════════════════════════
# PLASMA PANEL APPLY SCRIPT  (runs as user on first login)
# ══════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > /usr/lib/raptor/hud/apply-plasma-panel.sh
#!/bin/bash
kwriteconfig5 --file plasmarc --group Theme --key name RaptorOS
plasma-apply-colorscheme RaptorOS 2>/dev/null || \
    kwriteconfig5 --file kdeglobals --group General --key ColorScheme RaptorOS
kwriteconfig5 --file kwinrc --group org.kde.kdecoration2 --key library org.kde.kwin.aurorae
kwriteconfig5 --file kwinrc --group org.kde.kdecoration2 --key theme "__aurorae__svg__RaptorOS"

kwriteconfig5 --file kdeglobals --group KDE --key LookAndFeelPackage org.kde.breezedark.desktop
command -v kvantummanager &>/dev/null && kvantummanager --set RaptorOS 2>/dev/null || true

mkdir -p "${HOME}/.config/gtk-3.0"
cat << 'GTKEOF' > "${HOME}/.config/gtk-3.0/settings.ini"
[Settings]
gtk-theme-name=RaptorOS-GTK

gtk-cursor-theme-name=Adwaita
gtk-font-name=JetBrains Mono 10
gtk-application-prefer-dark-theme=1
GTKEOF

# ── Rebuild sycoca so the Raptor OS category is visible immediately ────────────
# Must run as the user at login time (not at build time) so the cache is
# written to the correct user/session paths and Plasma picks it up.
# Delete the stale cache first — kbuildsycoca6 --noincremental alone is not
# enough on Bazzite because the ostree image cache may shadow it.
rm -f "${HOME}/.cache/ksycoca6" \
      "${HOME}/.cache/kbuildsycoca6" \
      /var/tmp/kdecache-"${USER}"/ksycoca6 2>/dev/null || true

kbuildsycoca6 --noincremental 2>/dev/null || \
kbuildsycoca5 --noincremental 2>/dev/null || true

# ── Switch launcher from Kickoff → Kicker ────────────────────────────────────
# Kicker renders XDG categories as top-level cascading items; Kickoff buries
# them as subfolders. Find the actual panel containment ID dynamically
# instead of assuming ID=1 (Bazzite's panel IDs vary).
APPLETS="${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc"

if [ -f "$APPLETS" ]; then
    # Find containment IDs whose plugin is "org.kde.panel" (the taskbar)
    PANEL_IDS=$(grep -E "^\[Containments\]\[([0-9]+)\]$" "$APPLETS" | \
        grep -oE "[0-9]+" || true)

    for CID in $PANEL_IDS; do
        PLUGIN=$(kreadconfig5 --file "$APPLETS" \
            --group "Containments" --group "$CID" --key plugin 2>/dev/null || true)
        [ "$PLUGIN" = "org.kde.panel" ] || continue

        # Find the kickoff applet inside this panel
        APPLET_IDS=$(grep -E "^\[Containments\]\[$CID\]\[Applets\]\[([0-9]+)\]$" "$APPLETS" | \
            grep -oE "[0-9]+" | tail -n +2 || true)

        for AID in $APPLET_IDS; do
            APLUGIN=$(kreadconfig5 --file "$APPLETS" \
                --group "Containments" --group "$CID" \
                --group "Applets" --group "$AID" \
                --key plugin 2>/dev/null || true)
            if [ "$APLUGIN" = "org.kde.plasma.kickoff" ] || \
               [ "$APLUGIN" = "org.kde.plasma.kicker" ]; then
                kwriteconfig5 --file "$APPLETS" \
                    --group "Containments" --group "$CID" \
                    --group "Applets" --group "$AID" \
                    --key plugin "org.kde.plasma.kicker"
                kwriteconfig5 --file "$APPLETS" \
                    --group "Containments" --group "$CID" \
                    --group "Applets" --group "$AID" \
                    --group "Configuration" --group "General" \
                    --key showRecentApps false
                kwriteconfig5 --file "$APPLETS" \
                    --group "Containments" --group "$CID" \
                    --group "Applets" --group "$AID" \
                    --group "Configuration" --group "General" \
                    --key showRecentDocs false
                kwriteconfig5 --file "$APPLETS" \
                    --group "Containments" --group "$CID" \
                    --group "Applets" --group "$AID" \
                    --group "Configuration" --group "General" \
                    --key showRecentContacts false
                kwriteconfig5 --file "$APPLETS" \
                    --group "Containments" --group "$CID" \
                    --group "Applets" --group "$AID" \
                    --group "Configuration" --group "General" \
                    --key limitDepth false
                echo "Switched applet $AID in panel $CID to Kicker"
                break
            fi
        done
    done
fi

qdbus org.kde.KWin /KWin reconfigure 2>/dev/null || true
# Restart plasmashell so the launcher swap + new menu category both take effect
kquitapp6 plasmashell 2>/dev/null; sleep 1; plasmashell --replace &>/dev/null &
echo "RAPTOR_HUD_APPLIED"
EOF
chmod +x /usr/lib/raptor/hud/apply-plasma-panel.sh

# ══════════════════════════════════════════════════════════════════════════════
# GTK + KVANTUM THEMES
# ══════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > /usr/share/themes/RaptorOS-GTK/gtk-3.0/gtk.css
@define-color bg_color #151a20;
@define-color fg_color #c8d6e8;
@define-color base_color #0d0f12;
@define-color text_color #c8d6e8;
@define-color selected_bg_color #1e90ff;
@define-color selected_fg_color #ffffff;
@define-color tooltip_bg_color #0d0f12;
@define-color tooltip_fg_color #c8d6e8;
@define-color borders #2a3444;
@define-color accent #1e90ff;
* { -gtk-icon-style: symbolic; }
window, .background { background-color: @bg_color; color: @fg_color; }
headerbar { background: linear-gradient(to bottom, #1c2330, #151a20); border-bottom: 1px solid #1e90ff; padding: 4px 8px; min-height: 36px; }
headerbar .title { font-weight: 600; color: @fg_color; letter-spacing: 0.04em; }
button { background: #1c2330; border: 1px solid @borders; color: @fg_color; border-radius: 2px; padding: 4px 12px; transition: all 120ms ease; }
button:hover { background: #1e4a7a; border-color: @accent; color: white; }
button.suggested-action  { background: @accent; border-color: @accent; color: white; }
button.destructive-action { background: #8b1a1a; border-color: #cc3333; color: white; }
entry { background: @base_color; border: 1px solid @borders; color: @fg_color; border-radius: 2px; padding: 4px 8px; caret-color: @accent; }
entry:focus { border-color: @accent; box-shadow: 0 0 0 1px @accent; }
treeview.view:selected, row:selected { background-color: @selected_bg_color; color: @selected_fg_color; }
scrollbar slider { background-color: #2a3444; border-radius: 2px; min-width: 6px; min-height: 6px; }
scrollbar slider:hover { background-color: @accent; }
tooltip { background-color: @tooltip_bg_color; border: 1px solid @borders; color: @tooltip_fg_color; border-radius: 2px; }
menubar, .menubar { background-color: #1c2330; border-bottom: 1px solid @borders; }
menu, .menu { background-color: #151a20; border: 1px solid @borders; }
menu menuitem:hover { background-color: @accent; color: white; }
notebook header { background-color: #1c2330; border-bottom: 1px solid @borders; }
notebook header tab:checked { background-color: @base_color; border-bottom: 2px solid @accent; }
progressbar progress { background-color: @accent; border-radius: 2px; }
checkbutton check, radiobutton radio { background: @base_color; border: 1px solid @borders; }
checkbutton check:checked, radiobutton radio:checked { background-color: @accent; border-color: @accent; }
scale trough { background-color: #2a3444; border-radius: 2px; min-height: 4px; }
scale highlight { background-color: @accent; border-radius: 2px; }
EOF
cp /usr/share/themes/RaptorOS-GTK/gtk-3.0/gtk.css /usr/share/themes/RaptorOS-GTK/gtk-4.0/gtk.css

cat << 'EOF' > /usr/share/themes/RaptorOS-GTK/index.theme
[Desktop Entry]
Type=X-GNOME-Metatheme
Name=RaptorOS-GTK
Comment=F-22 Raptor themed GTK style
Encoding=UTF-8

[X11 Properties]
GtkTheme=RaptorOS-GTK
MetacityTheme=RaptorOS-GTK

CursorTheme=Adwaita
ButtonLayout=close,minimize,maximize:

[KDE]
WidgetStyle=kvantum
EOF

cat << 'EOF' > /usr/share/Kvantum/RaptorOS/RaptorOS.kvconfig
[%General]
author=RaptorOS
comment=F-22 Raptor stealth dark theme
x11drag=all
composite=true
menu_shadow_depth=6
tooltip_shadow_depth=4
popup_blurring=true
contrast=1.0
intensity=1.0
saturation=1.0

[GeneralColors]
window.color=#1c2330
base.color=#0d0f12
alt.base.color=#151a20
button.color=#1c2330
light.color=#2a3a4e
mid.light.color=#1e2d3e
mid.color=#151a20
dark.color=#0a0c0f
shadow.color=#000000
highlight.color=#1e90ff
inactive.highlight.color=#2a3444
text.color=#c8d6e8
window.text.color=#c8d6e8
button.text.color=#c8d6e8
disabled.text.color=#5a6a7e
tooltip.base.color=#0d0f12
tooltip.text.color=#c8d6e8
link.color=#1e90ff
link.visited.color=#8c64dc
progress.indicator.text.color=#ffffff

[Hacks]
transparent_ktitle_label=true
blur_konsole=true
EOF
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><rect width="200" height="200" fill="#1c2330"/></svg>' \
    > /usr/share/Kvantum/RaptorOS/RaptorOS.svg

# ══════════════════════════════════════════════════════════════════════════════
# KONSOLE PROFILE + COLOR SCHEME
# ══════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > /usr/share/konsole/RaptorOS.profile
[Appearance]
ColorScheme=RaptorOS
Font=JetBrains Mono,11,-1,5,50,0,0,0,0,0
LineSpacing=2

[General]
Command=/bin/bash
Icon=utilities-terminal
Name=RaptorOS
Parent=FALLBACK/
TerminalColumns=120
TerminalRows=36

[Scrolling]
HistoryMode=2
HistorySize=10000
ScrollBarPosition=2

[Terminal Features]
BlinkingCursorEnabled=true
CursorShape=1
EOF

cat << 'EOF' > /usr/share/konsole/RaptorOS.colorscheme
[Background]
Color=13,15,18
[BackgroundIntense]
Color=21,26,32
[Color0]
Color=21,26,32
[Color0Intense]
Color=42,52,68
[Color1]
Color=180,50,50
[Color1Intense]
Color=220,80,80
[Color2]
Color=46,160,100
[Color2Intense]
Color=46,194,126
[Color3]
Color=200,130,30
[Color3Intense]
Color=245,166,35
[Color4]
Color=30,100,200
[Color4Intense]
Color=30,144,255
[Color5]
Color=100,60,180
[Color5Intense]
Color=140,100,220
[Color6]
Color=30,140,180
[Color6Intense]
Color=30,180,220
[Color7]
Color=160,180,200
[Color7Intense]
Color=200,214,232
[Foreground]
Color=200,214,232
[ForegroundIntense]
Color=230,240,255
[General]
Anchor=0.5,0.5
Blur=true
BlurRadius=12
ColorRandomization=false
Description=RaptorOS
Opacity=0.92
EOF

# ══════════════════════════════════════════════════════════════════════════════
# FIRSTBOOT SYSTEMD USER SERVICE
# ══════════════════════════════════════════════════════════════════════════════
cat << 'EOF' > /usr/lib/systemd/user/raptor-hud-apply.service
[Unit]
Description=Raptor HUD — Apply KDE theme on first login
# Run after plasmashell is up so kwriteconfig5 and plasmashell --replace work
After=plasma-plasmashell.service
# Guard file lives in the user's home so it works on immutable/ostree systems.
# Delete ~/.config/raptor-hud-applied to re-run (e.g. after a rebase).
ConditionPathExists=!%h/.config/raptor-hud-applied

[Service]
Type=oneshot
ExecStart=/usr/lib/raptor/hud/apply-plasma-panel.sh
ExecStartPost=/usr/bin/touch %h/.config/raptor-hud-applied
RemainAfterExit=yes

[Install]
WantedBy=plasma-plasmashell.service
EOF

systemctl --global enable raptor-hud-apply.service  2>/dev/null || true
systemctl --global enable raptor-drkonqi.service     2>/dev/null || true

# ── Rebuild menu DB so category + .desktop appear immediately ──────────────────
if command -v kbuildsycoca6 &>/dev/null; then
    kbuildsycoca6 --noincremental
elif command -v kbuildsycoca5 &>/dev/null; then
    kbuildsycoca5 --noincremental
fi

cat << 'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RAPTOR HUD — INSTALL COMPLETE

  Installs:
  • KDE color scheme, Aurorae decoration, Kvantum + GTK themes
  • Konsole RaptorOS profile + color scheme
  • "Raptor OS" app launcher category (applications.menu + kde-)
  • KDE default taskbar and icons kept — launcher swapped to Kicker
    so "Raptor OS" appears as a top-level category in the menu
  • GPU profile detection service + TUI profiler (launcher .desktop)
  • drkonqi suppressed by default via /etc/xdg/kcrashrc +
    raptor-drkonqi.service — toggle in profiler TUI with [6]

  recipe.yml rpm-ostree installs needed:
    - kvantum  - kvantum-qt5
    - jetbrains-mono-fonts  - qt5-qtbase

  Reset HUD apply (re-runs on next login):
    rm ~/.config/raptor-hud-applied
    systemctl --user start raptor-hud-apply.service
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

echo "RAPTOR_HUD_READY"

# ── One-time migration: fix stale mimeapps + Dolphin defaults ───────────────
# Dolphin is the default file browser again. Users may carry stale personal
# configs (from the short Nautilus era, or plain KDE defaults): "inode/
# directory=…" in their own ~/.config/mimeapps.list outranks /etc/xdg, so it
# must be corrected per-user. Same for dolphinrc: without a personal file the
# /etc/xdg/dolphinrc stability keys apply, but an existing ~/.config/dolphinrc
# would override them silently. This script runs once at login per stamp file,
# corrects only the targeted keys, and leaves every other user preference alone.
#
# v2: Dolphin's "Hide the F4 preview panel" key is [InformationPanel] with
# previewsShown/previewsAutoPlay/showHovered — the old "[General] ShowPreview"
# key does not exist and was silently ignored, so the archive-selection freeze
# persisted. Stamp renamed (…-v2) so anyone who already ran the v1 migration
# gets the corrected keys applied once.
mkdir -p /usr/lib/raptor /etc/xdg/autostart

cat << 'MIGRATIONEOF' > /usr/lib/raptor/cleanup-legacy-mimeapps.sh
#!/bin/bash
set -euo pipefail
STAMP_DIR="$HOME/.local/share/raptor"
STAMP="$STAMP_DIR/raptor-dolphin-defaults-v2"
[ -f "$STAMP" ] && exit 0

python3 - << 'INNERPYEOF'
import os

MIME_PATH = os.path.expanduser("~/.config/mimeapps.list")
DOLPHINRC_PATH = os.path.expanduser("~/.config/dolphinrc")

DESIRED_MIME = {
    "inode/directory":            "org.kde.dolphin.desktop",
    "image/png":                   "org.kde.gwenview.desktop",
    "image/jpeg":                  "org.kde.gwenview.desktop",
    "image/gif":                   "org.kde.gwenview.desktop",
    "image/webp":                  "org.kde.gwenview.desktop",
    "image/bmp":                   "org.kde.gwenview.desktop",
    "image/svg+xml":               "org.kde.gwenview.desktop",
    "image/tiff":                  "org.kde.gwenview.desktop",
    "image/x-portable-pixmap":     "org.kde.gwenview.desktop",
    "application/zip":             "org.kde.ark.desktop",
    "application/x-tar":           "org.kde.ark.desktop",
    "application/x-compressed-tar":"org.kde.ark.desktop",
    "application/x-7z-compressed": "org.kde.ark.desktop",
    "application/x-rar":           "org.kde.ark.desktop",
    "application/x-bzip":          "org.kde.ark.desktop",
    "application/x-bzip-compressed-tar": "org.kde.ark.desktop",
    "application/gzip":            "org.kde.ark.desktop",
    "application/x-xz":            "org.kde.ark.desktop",
    "application/x-ms-dos-executable":              "raptor-wine.desktop",
    "application/x-msi":                            "raptor-wine.desktop",
    "application/vnd.microsoft.portable-executable":"raptor-wine.desktop",
    "application/x-msdownload":                     "raptor-wine.desktop",
}

DESIRED_DOLPHIN = {
    # (section, key) -> value
    ("InformationPanel", "previewsShown"):    "false",
    ("InformationPanel", "previewsAutoPlay"): "false",
    ("InformationPanel", "showHovered"):      "false",
    ("PreviewSettings", "Plugins"):           "imagethumbnail,directorythumbnail",
}

DESIRED_BALOO = {
    ("Basic Settings", "IndexFileContent"):  "false",
    ("Basic Settings", "IndexFileSizeLimit"):  "4",
    ("Basic Settings", "IndexVideoSizeLimit"): "8",
    ("Basic Settings", "IndexImageSizeLimit"): "4",
    ("General", "exclude filters"): (
        "*.zip *.tar *.gz *.tgz *.tar.gz *.bz2 *.tbz2 *.tar.bz2 "
        "*.7z *.rar *.xz *.lzma *.lz *.zst "
        "*.iso *.img *.dmg *.cab *.deb *.rpm *.AppImage *.appimage"
    ),
}

def ensure_keys(path, heading, desired):
    """Make every desired key under `heading` exist with the right value,
    preserving everything else in the file. KConfig-style [Section] INI."""
    if not os.path.exists(path):
        with open(path, "w") as f:
            f.write(heading + "\n")
            for k, v in desired.items():
                f.write(f"{k}={v}\n")
        return
    with open(path) as f:
        lines = f.read().splitlines()
    in_section = False
    seen = set()
    out = []
    section_end = None
    changed = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            if in_section and section_end is None:
                section_end = len(out)
            in_section = (stripped == heading)
            out.append(line)
            continue
        if in_section and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in desired:
                seen.add(key)
                want = f"{key}={desired[key]}"
                if stripped != want:
                    out.append(want)
                    changed = True
                    continue
        out.append(line)
    if in_section and section_end is None:
        section_end = len(out)
    missing = [k for k in desired if k not in seen]
    if missing:
        if section_end is None:
            out.append("")
            out.append(heading)
            for k in missing:
                out.append(f"{k}={desired[k]}")
        else:
            insertion = [f"{k}={desired[k]}" for k in missing]
            out = out[:section_end] + insertion + out[section_end:]
        changed = True
    if changed:
        with open(path, "w") as f:
            for line in out:
                f.write(line)
                f.write("\n")

ensure_keys(MIME_PATH, "[Default Applications]", DESIRED_MIME)
dolphin_by_section = {}
for (sec, k), v in DESIRED_DOLPHIN.items():
    dolphin_by_section.setdefault(sec, {})[k] = v
for sec, desired in dolphin_by_section.items():
    ensure_keys(DOLPHINRC_PATH, f"[{sec}]", desired)
baloorc = os.path.expanduser("~/.config/baloorc")
baloo_by_section = {}
for (sec, k), v in DESIRED_BALOO.items():
    baloo_by_section.setdefault(sec, {})[k] = v
for sec, desired in baloo_by_section.items():
    ensure_keys(baloorc, f"[{sec}]", desired)
print("raptor-dolphin-defaults-applied")
INNERPYEOF

mkdir -p "$STAMP_DIR"
touch "$STAMP"
MIGRATIONEOF
chmod +x /usr/lib/raptor/cleanup-legacy-mimeapps.sh

cat << 'DESKTOPEOF' > /etc/xdg/autostart/raptor-cleanup-legacy-mimeapps.desktop
[Desktop Entry]
Type=Application
Name=Raptor OS File Manager Defaults
Comment=Dolphin default file browser, archive handler and stability keys
Exec=/usr/lib/raptor/cleanup-legacy-mimeapps.sh
Terminal=false
Hidden=false
X-KDE-autostart-phase=1
NoDisplay=true
DESKTOPEOF
