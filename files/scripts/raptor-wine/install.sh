#!/bin/bash
set -euo pipefail

# Raptor Wine keeps the ordinary Wine workflow intact. The system "wine"
# command, default ~/.wine prefix, winecfg, wineboot, wineserver and winetricks
# remain the primary interface. Raptor adds simple desktop integration and an
# optional Proton path for games that benefit from Proton's runtime/patches.

command -v wine >/dev/null 2>&1 || {
  echo "RAPTOR_WINE_ERROR: Wine is not installed" >&2
  exit 1
}
command -v umu-run >/dev/null 2>&1 || {
  echo "RAPTOR_WINE_ERROR: UMU is not installed" >&2
  exit 1
}

cat <<'WINE' > /usr/bin/raptor-wine
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  exec wine
fi

first="$1"
case "${first,,}" in
  *.msi)
    shift
    exec wine msiexec /i "$first" "$@"
    ;;
  *.exe|*.com|*.bat)
    exec wine "$@"
    ;;
  *)
    # Preserve Wine's normal command semantics for winecfg, wineboot,
    # regedit, control, arbitrary commands, and caller-supplied options.
    exec wine "$@"
    ;;
esac
WINE
chmod 0755 /usr/bin/raptor-wine

cat <<'PROTON' > /usr/bin/raptor-wine-proton
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Raptor Proton — optional Proton-powered Windows game launcher.

Usage:
  raptor-wine-proton game.exe [arguments...]

Normal Windows applications continue to use:
  wine program.exe

Proton supplies its own game-focused compatibility patches and graphics
translation (including DXVK/VKD3D where supported) inside UMU's Steam Linux
Runtime. The Steam client is not required.

Optional environment settings:
  RAPTOR_WINE_GAME_ID   UMU database ID (default: umu-default)
  RAPTOR_WINE_STORE     Store ID for supported UMU fixes
  RAPTOR_WINE_PROTONPATH Proton directory/version (default: UMU-Proton)
  RAPTOR_WINE_DEBUG=1   Enable UMU and Proton diagnostic logs
HELP
  [[ $# -gt 0 ]] || exit 0
fi

command -v umu-run >/dev/null 2>&1 || {
  echo "raptor-wine-proton: UMU is not installed." >&2
  exit 1
}

# Let UMU manage its standard default Proton prefix. Respect a caller-supplied
# WINEPREFIX, but do not force users into a custom prefix/profile workflow.
export GAMEID="${RAPTOR_WINE_GAME_ID:-umu-default}"
[[ -z "${RAPTOR_WINE_STORE:-}" ]] || export STORE="$RAPTOR_WINE_STORE"
[[ -z "${RAPTOR_WINE_PROTONPATH:-}" ]] || export PROTONPATH="$RAPTOR_WINE_PROTONPATH"

if [[ "${RAPTOR_WINE_DEBUG:-0}" == "1" ]]; then
  export UMU_LOG=1
  export PROTON_LOG=1
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: raptor-wine-proton program.exe [arguments...]" >&2
  exit 2
fi

target="$1"
shift

case "${target,,}" in
  *.msi)
    exec umu-run wine msiexec /i "$target" "$@"
    ;;
  *)
    exec umu-run "$target" "$@"
    ;;
esac
PROTON
chmod 0755 /usr/bin/raptor-wine-proton

cat <<'DESKTOP' > /usr/share/applications/raptor-wine.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Open with Raptor Wine
GenericName=Windows program
Comment=Run Windows applications with standard Wine
Exec=raptor-wine %f
Icon=application-x-ms-dos-executable
Terminal=false
NoDisplay=true
MimeType=application/x-ms-dos-executable;application/x-msi;application/vnd.microsoft.portable-executable;application/x-msdownload;
DESKTOP

cat <<'PROTONDESKTOP' > /usr/share/applications/raptor-wine-proton.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Run with Raptor Proton
GenericName=Windows game
Comment=Run a Windows game with Proton and UMU
Exec=raptor-wine-proton %f
Icon=applications-games
Terminal=false
NoDisplay=true
MimeType=application/x-ms-dos-executable;application/vnd.microsoft.portable-executable;application/x-msdownload;
PROTONDESKTOP

mkdir -p /usr/share/kio/servicemenus
cat <<'SERVICE' > /usr/share/kio/servicemenus/raptor-wine.desktop
[Desktop Entry]
Type=Service
X-KDE-ServiceTypes=KonqPopupMenu/Plugin
MimeType=application/x-ms-dos-executable;application/x-msi;application/vnd.microsoft.portable-executable;application/x-msdownload;
Actions=raptorWineRun;raptorProtonRun;
X-KDE-Priority=TopLevel

[Desktop Action raptorWineRun]
Name=Open with Raptor Wine
Icon=application-x-ms-dos-executable
Exec=raptor-wine %f

[Desktop Action raptorProtonRun]
Name=Run with Raptor Proton (games)
Icon=applications-games
Exec=raptor-wine-proton %f
SERVICE

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

for required in /usr/bin/raptor-wine /usr/bin/raptor-wine-proton /usr/share/applications/raptor-wine.desktop /usr/share/applications/raptor-wine-proton.desktop /usr/share/kio/servicemenus/raptor-wine.desktop; do
  [[ -s "$required" ]] || { echo "RAPTOR_WINE_PAYLOAD_MISSING:$required" >&2; exit 1; }
done
bash -n /usr/bin/raptor-wine
bash -n /usr/bin/raptor-wine-proton
echo "RAPTOR_WINE_READY: standard Wine workflow plus optional per-game Proton integration"
