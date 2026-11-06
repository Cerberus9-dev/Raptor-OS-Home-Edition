#!/bin/bash
set -euo pipefail

# Raptor Wine: regular Wine for desktop apps and UMU/Proton for games.

cat <<'LAUNCHER' > /usr/bin/raptor-wine
#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/raptor-wine"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/winetricks"
RUNTIME_TIMEOUT="${RAPTOR_WINE_RUNTIME_TIMEOUT:-300}"
PREFIX_NAME="default"
PREFIX_EXPLICIT=0
RUNNER="auto"
GAME_ID="${RAPTOR_WINE_GAME_ID:-umu-default}"
STORE="${RAPTOR_WINE_STORE:-}"
PROTON_VERSION="${RAPTOR_WINE_PROTONPATH:-}"
RESET=0
BOOTSTRAP=1
INSTALL_RUNTIME=""
DEBUG=0

usage() {
  cat <<'HELP'
Raptor Wine — Windows desktop apps and games, without requiring Steam.

Usage:
  raptor-wine [OPTIONS] <program.exe|program.msi> [arguments...]
  raptor-wine [OPTIONS]                 (opens a desktop file picker)

Runners:
  --runner auto       Ask in the desktop UI; terminal defaults to Wine
  --runner wine       Regular Wine for desktop applications
  --runner proton     UMU + Proton for games and Proton-specific compatibility

Options:
  --prefix NAME          Isolate this application's Wine prefix
  --game-id ID           Optional UMU database ID (default: umu-default)
  --store STORE          Optional storefront ID for UMU protonfixes
  --proton-version PATH  Proton directory/name; defaults to UMU-Proton
  --install-runtime VERB Install a Winetricks component in this prefix
  --no-bootstrap         Skip Wine's common MSVC/font bootstrap
  --reset                Recreate only the selected runner's prefix
  --debug                Enable UMU/Proton diagnostic logging
  -h, --help             Show this help

UMU runs Proton with its expected Steam Linux Runtime, but does not require
the Steam client or a Steam game library. First use downloads runtime files.
HELP
}

while (($#)); do
  case "$1" in
    --runner) [[ $# -ge 2 ]] || { echo "raptor-wine: --runner needs auto, wine, or proton" >&2; exit 2; }; RUNNER="$2"; shift 2 ;;
    --prefix) [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --prefix needs a name" >&2; exit 2; }; PREFIX_NAME="$2"; PREFIX_EXPLICIT=1; shift 2 ;;
    --game-id) [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --game-id needs an ID" >&2; exit 2; }; GAME_ID="$2"; shift 2 ;;
    --store) [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --store needs a value" >&2; exit 2; }; STORE="$2"; shift 2 ;;
    --proton-version) [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --proton-version needs a path or version" >&2; exit 2; }; PROTON_VERSION="$2"; shift 2 ;;
    --install-runtime) [[ $# -ge 2 && -n "$2" ]] || { echo "raptor-wine: --install-runtime needs a Winetricks verb" >&2; exit 2; }; INSTALL_RUNTIME="$2"; shift 2 ;;
    --no-bootstrap) BOOTSTRAP=0; shift ;;
    --reset) RESET=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "raptor-wine: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

if (( PREFIX_EXPLICIT == 0 )) && [[ -n "${1:-}" && -n "$INSTALL_RUNTIME" ]]; then
  :
elif (( PREFIX_EXPLICIT == 0 )) && [[ -n "${1:-}" ]]; then
  app_name="$(basename -- "$1")"
  app_name="${app_name%.*}"
  app_name="${app_name,,}"
  PREFIX_NAME="$(printf '%s' "$app_name" | sed -E 's/[^a-z0-9._-]+/-/g; s/^[.-]+//; s/[.-]+$//')"
  [[ -n "$PREFIX_NAME" ]] || PREFIX_NAME="default"
fi
[[ "$PREFIX_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "raptor-wine: invalid prefix name" >&2; exit 2; }
[[ "$RUNNER" == auto || "$RUNNER" == wine || "$RUNNER" == proton ]] || { echo "raptor-wine: runner must be auto, wine, or proton" >&2; exit 2; }

if [[ -z "$INSTALL_RUNTIME" && $# -eq 0 ]]; then
  if command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    selected_file="$(zenity --file-selection --title='Choose a Windows application or game' --file-filter='Windows programs (*.exe *.msi) | *.exe *.msi' 2>/dev/null)" || exit 0
    set -- "$selected_file"
  else
    usage >&2
    exit 2
  fi
fi

if [[ "$RUNNER" == auto ]]; then
  if command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    choice="$(zenity --list --radiolist --title='Raptor Wine' --text='Choose the compatibility mode for this Windows program.' --column='Use' --column='Runner' TRUE 'Wine — desktop application' FALSE 'Proton — Windows game / enhanced compatibility' --height=230 2>/dev/null)" || exit 0
    case "$choice" in
      'Proton — Windows game / enhanced compatibility') RUNNER=proton ;;
      *) RUNNER=wine ;;
    esac
  else
    RUNNER=wine
  fi
fi

PREFIX_PATH="$DATA_DIR/$RUNNER/$PREFIX_NAME"
RUNTIME_LOG="$DATA_DIR/$RUNNER/$PREFIX_NAME.runtimes.log"
RUNTIME_STAMP="$DATA_DIR/$RUNNER/$PREFIX_NAME.runtimes-done"
mkdir -p "$DATA_DIR/$RUNNER" "$CACHE_DIR"
export WINEPREFIX="$PREFIX_PATH"
export WINEDEBUG="${WINEDEBUG:--all}"

if [[ "$RUNNER" == wine ]]; then
  WINE_BIN="${WINE:-wine}"
  command -v "$WINE_BIN" >/dev/null 2>&1 || { echo "raptor-wine: Wine is not installed" >&2; exit 1; }
  CMD_WINE="$(command -v "$WINE_BIN")"
  command -v wineboot >/dev/null 2>&1 || { echo "raptor-wine: wineboot is not installed" >&2; exit 1; }
  if (( RESET )); then
    "$CMD_WINE" wineserver -k >/dev/null 2>&1 || true
    rm -rf -- "$PREFIX_PATH"
    rm -f -- "$RUNTIME_STAMP"
  fi
  if [[ ! -s "$PREFIX_PATH/system.reg" ]]; then
    mkdir -p "$PREFIX_PATH"
    wineboot -u
  fi
  if (( BOOTSTRAP )) && [[ -z "$INSTALL_RUNTIME" && ! -f "$RUNTIME_STAMP" ]]; then
    if command -v winetricks >/dev/null 2>&1; then
      echo "raptor-wine: installing common desktop runtimes (one-time)..."
      if timeout "$RUNTIME_TIMEOUT" winetricks --unattended --quiet vcrun2015 vcrun2019 corefonts >>"$RUNTIME_LOG" 2>&1; then
        touch "$RUNTIME_STAMP"
      else
        echo "raptor-wine: runtime setup deferred; see $RUNTIME_LOG. The program will still be launched." >&2
      fi
    else
      echo "raptor-wine: Winetricks unavailable; skipping optional runtime bootstrap." >&2
    fi
  fi
  if [[ -n "$INSTALL_RUNTIME" ]]; then
    command -v winetricks >/dev/null 2>&1 || { echo "raptor-wine: Winetricks is not installed" >&2; exit 1; }
    exec winetricks --unattended --quiet "$INSTALL_RUNTIME"
  fi
  if [[ "${1,,}" == *.msi ]]; then
    installer="$1"; shift
    exec "$CMD_WINE" msiexec /i "$installer" "$@"
  fi
  exec "$CMD_WINE" "$@"
fi

# Game runner: UMU supplies Proton's expected Steam Linux Runtime without
# requiring the Steam client or Steam game library.
command -v umu-run >/dev/null 2>&1 || { echo "raptor-wine: UMU launcher is missing; install the umu-launcher package." >&2; exit 1; }
if (( RESET )); then
  rm -rf -- "$PREFIX_PATH"
fi
export GAMEID="$GAME_ID"
[[ -z "$STORE" ]] || export STORE
[[ -z "$PROTON_VERSION" ]] || export PROTONPATH="$PROTON_VERSION"
if (( DEBUG )); then export UMU_LOG=1; export PROTON_LOG=1; fi
if [[ -n "$INSTALL_RUNTIME" ]]; then
  exec umu-run winetricks "$INSTALL_RUNTIME"
fi
if [[ "${1,,}" == *.msi ]]; then
  installer="$1"; shift
  exec umu-run wine msiexec /i "$installer" "$@"
fi
exec umu-run "$@"
LAUNCHER
chmod 0755 /usr/bin/raptor-wine

cat <<'DESKTOP' > /usr/share/applications/raptor-wine.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Raptor Wine
GenericName=Windows application and game launcher
Comment=Run Windows programs with Wine or Steam-independent Proton
Exec=raptor-wine
Icon=application-x-ms-dos-executable
Terminal=false
Categories=System;Utility;Game;
Keywords=wine;windows;exe;msi;proton;umu;game;application;
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
Name=Run with Raptor Wine
Icon=application-x-ms-dos-executable
Exec=raptor-wine --runner auto %f
SERVICE

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
for required in /usr/bin/raptor-wine /usr/share/applications/raptor-wine.desktop /usr/share/kio/servicemenus/raptor-wine.desktop; do
  [[ -s "$required" ]] || { echo "RAPTOR_WINE_PAYLOAD_MISSING:$required" >&2; exit 1; }
done
bash -n /usr/bin/raptor-wine
echo "RAPTOR_WINE_READY: Wine + UMU/Proton launcher installed"
