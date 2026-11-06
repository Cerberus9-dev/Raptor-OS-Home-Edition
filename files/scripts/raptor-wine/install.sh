#!/bin/bash
set -euo pipefail

# Raptor OS — general-purpose Wine launcher.
# Bootstrap common desktop-app runtimes, but never force game-only DXVK/Proton
# settings into ordinary Windows application prefixes.

cat <<'LAUNCHER' > /usr/bin/raptor-wine
#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/raptor-wine"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/winetricks"
DEFAULT_RUNTIMES=(vcrun2015 vcrun2019 corefonts)
RUNTIME_TIMEOUT="${RAPTOR_WINE_RUNTIME_TIMEOUT:-300}"
PREFIX_NAME="default"
RESET=0
BOOTSTRAP=1
INSTALL_RUNTIME=""

usage() {
    cat <<'HELP'
Usage: raptor-wine [OPTIONS] <program.exe|program.msi> [arguments...]

Runs Windows desktop applications in an isolated Wine prefix. On first use,
Raptor Wine attempts a one-time install of common MSVC runtimes and fonts.
This does not install DXVK or apply gaming-only graphics overrides.

Options:
  --prefix NAME          Use ~/.local/share/raptor-wine/NAME
  --reset                Stop Wine and recreate the selected prefix
  --install-runtime VERB Install one optional Winetricks component and exit
  --no-bootstrap         Skip the automatic MSVC/font runtime setup
  -h, --help             Show this help

For Windows games, use Steam with Proton or a dedicated gaming manager.
HELP
}

while (($#)); do
    case "$1" in
        --prefix)
            [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --prefix needs a name" >&2; exit 2; }
            PREFIX_NAME="$2"; shift 2 ;;
        --reset) RESET=1; shift ;;
        --install-runtime)
            [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --install-runtime needs a verb" >&2; exit 2; }
            INSTALL_RUNTIME="$2"; shift 2 ;;
        --no-bootstrap) BOOTSTRAP=0; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "raptor-wine: unknown option $1" >&2; usage >&2; exit 2 ;;
        *) break ;;
    esac
done

[[ "$PREFIX_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "raptor-wine: invalid prefix name" >&2; exit 2; }
[[ -n "$INSTALL_RUNTIME" || $# -gt 0 ]] || { usage >&2; exit 2; }

WINE_BIN="${WINE:-wine}"
command -v "$WINE_BIN" >/dev/null 2>&1 || { echo "raptor-wine: Wine is not installed" >&2; exit 1; }
CMD_WINE="$(command -v "$WINE_BIN")"
command -v wineboot >/dev/null 2>&1 || { echo "raptor-wine: wineboot is not installed" >&2; exit 1; }

PREFIX_PATH="$DATA_DIR/$PREFIX_NAME"
RUNTIME_LOG="$DATA_DIR/$PREFIX_NAME.runtimes.log"
RUNTIME_STAMP="$DATA_DIR/$PREFIX_NAME.runtimes-done"
export WINEPREFIX="$PREFIX_PATH"
export WINEDEBUG="${WINEDEBUG:--all}"
mkdir -p "$DATA_DIR" "$CACHE_DIR"

if (( RESET )); then
    "$CMD_WINE" wineserver -k >/dev/null 2>&1 || true
    rm -rf -- "$PREFIX_PATH"
    rm -f -- "$RUNTIME_STAMP"
    echo "raptor-wine: prefix '$PREFIX_NAME' reset."
fi

if [[ ! -s "$PREFIX_PATH/system.reg" ]]; then
    mkdir -p "$PREFIX_PATH"
    echo "raptor-wine: initializing prefix '$PREFIX_NAME'..."
    wineboot -u
fi

# Common desktop runtimes are installed once, best-effort, and retried on a
# later launch if the network/download fails. DXVK is deliberately excluded:
# ordinary desktop apps should not receive a forced game graphics stack.
if (( BOOTSTRAP )) && [[ -z "$INSTALL_RUNTIME" && ! -f "$RUNTIME_STAMP" ]]; then
    if command -v winetricks >/dev/null 2>&1; then
        echo "raptor-wine: installing common MSVC runtimes and fonts (one-time)..."
        if timeout "$RUNTIME_TIMEOUT" winetricks --unattended --quiet "${DEFAULT_RUNTIMES[@]}" >>"$RUNTIME_LOG" 2>&1; then
            touch "$RUNTIME_STAMP"
            echo "raptor-wine: common runtimes installed."
        else
            echo "raptor-wine: runtime setup was deferred; the app will still be launched." >&2
            echo "raptor-wine: check $RUNTIME_LOG, then retry or install a component with --install-runtime." >&2
        fi
    else
        echo "raptor-wine: Winetricks unavailable; common runtimes were not installed." >&2
    fi
fi

if [[ -n "$INSTALL_RUNTIME" ]]; then
    command -v winetricks >/dev/null 2>&1 || { echo "raptor-wine: Winetricks is not installed" >&2; exit 1; }
    exec winetricks --unattended --quiet "$INSTALL_RUNTIME"
fi

# No forced WINEESYNC/WINEFSYNC, DXVK, VKD3D, or DLL overrides. Respect the
# user's environment and let Wine select the appropriate desktop defaults.
if [[ "${1,,}" == *.msi ]]; then
    installer="$1"; shift
    exec "$CMD_WINE" msiexec /i "$installer" "$@"
fi
exec "$CMD_WINE" "$@"
LAUNCHER
chmod 0755 /usr/bin/raptor-wine

cat <<'DESKTOP' > /usr/share/applications/raptor-wine.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Windows Application (Raptor Wine)
GenericName=Launch Windows app
Comment=Run a Windows desktop application with Wine
Exec=raptor-wine %U
Icon=application-x-ms-dos-executable
Terminal=false
Categories=X-RaptorOS;System;Utility;
MimeType=application/x-ms-dos-executable;application/x-msi;application/vnd.microsoft.portable-executable;application/x-msdownload;
Keywords=wine;windows;exe;msi;application;
NoDisplay=true
DESKTOP

mkdir -p /usr/share/kio/servicemenus
cat <<'SERVICE' > /usr/share/kio/servicemenus/raptor-wine.desktop
[Desktop Entry]
Type=Service
X-KDE-ServiceTypes=KonqPopupMenu/Plugin
MimeType=application/x-ms-dos-executable;application/x-msi;application/vnd.microsoft.portable-executable;application/x-msdownload;
Actions=raptorWineRun;
X-KDE-Priority=TopLevel

[Desktop Action raptorWineRun]
Name=Run as Windows App (Raptor Wine)
Icon=application-x-ms-dos-executable
Exec=raptor-wine %f
SERVICE

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
for required in /usr/bin/raptor-wine /usr/share/applications/raptor-wine.desktop /usr/share/kio/servicemenus/raptor-wine.desktop; do
    [[ -s "$required" ]] || { echo "RAPTOR_WINE_PAYLOAD_MISSING:$required" >&2; exit 1; }
done
bash -n /usr/bin/raptor-wine
echo "RAPTOR_WINE_READY: general-purpose Wine launcher installed"
