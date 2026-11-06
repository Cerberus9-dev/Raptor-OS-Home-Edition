#!/bin/bash
set -euo pipefail

# Raptor OS — general-purpose Wine launcher.
# Wine is for ordinary Windows desktop applications. Proton remains an optional,
# game-oriented Steam compatibility tool and is never injected into Wine prefixes.

cat <<'LAUNCHER' > /usr/bin/raptor-wine
#!/usr/bin/env bash
set -euo pipefail
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/raptor-wine"
PREFIX_NAME="default"
RESET=0
INSTALL_RUNTIME=""
while (($#)); do
    case "$1" in
        --prefix) [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --prefix needs a name" >&2; exit 2; }; PREFIX_NAME="$2"; shift 2 ;;
        --reset) RESET=1; shift ;;
        --install-runtime) [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --install-runtime needs a verb" >&2; exit 2; }; INSTALL_RUNTIME="$2"; shift 2 ;;
        -h|--help)
            cat <<'HELP'
Usage: raptor-wine [--prefix NAME] [--reset] [--install-runtime VERB] <program.exe|program.msi> [arguments...]
Runs ordinary Windows desktop applications in an isolated Wine prefix.
No game-only graphics components or large runtime bundles are installed automatically.
Options:
  --prefix NAME          Use ~/.local/share/raptor-wine/NAME
  --reset                Recreate that prefix before launching
  --install-runtime VERB Install one optional Winetricks component, then exit
  -h, --help             Show this help
For Windows games, use Steam with Proton or a dedicated gaming manager.
HELP
            exit 0 ;;
        --) shift; break ;;
        -*) echo "raptor-wine: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[[ "$PREFIX_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "raptor-wine: invalid prefix name" >&2; exit 2; }
[[ -n "$INSTALL_RUNTIME" || $# -gt 0 ]] || { echo "raptor-wine: no Windows program supplied (try --help)" >&2; exit 2; }
command -v wine >/dev/null 2>&1 || { echo "raptor-wine: Wine is not installed" >&2; exit 1; }
command -v wineboot >/dev/null 2>&1 || { echo "raptor-wine: wineboot is not installed" >&2; exit 1; }
PREFIX_PATH="$DATA_DIR/$PREFIX_NAME"
export WINEPREFIX="$PREFIX_PATH"
export WINEDEBUG="${WINEDEBUG:--all}"
mkdir -p "$DATA_DIR"
if (( RESET )); then
    [[ ! -d "$PREFIX_PATH" ]] || { wineboot -e >/dev/null 2>&1 || true; rm -rf -- "$PREFIX_PATH"; }
fi
if [[ ! -s "$PREFIX_PATH/system.reg" ]]; then
    mkdir -p "$PREFIX_PATH"
    echo "raptor-wine: initializing prefix '$PREFIX_NAME'..."
    wineboot -u
fi
# Optional components are installed only when explicitly requested.
# No DXVK/D3D overrides are forced onto ordinary desktop applications.
if [[ -n "$INSTALL_RUNTIME" ]]; then
    command -v winetricks >/dev/null 2>&1 || { echo "raptor-wine: Winetricks is not installed" >&2; exit 1; }
    exec winetricks --unattended "$INSTALL_RUNTIME"
fi
# Respect caller-provided Wine tuning. Do not force game-only sync or graphics settings.
if [[ "${1,,}" == *.msi ]]; then
    installer="$1"; shift
    exec wine msiexec /i "$installer" "$@"
fi
exec wine "$@"
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
