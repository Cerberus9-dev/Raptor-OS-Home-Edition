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
    echo "raptor-wine-proton: MSI installers should be run with standard Wine:" >&2
    echo "  wine msiexec /i \"$target\"" >&2
    exit 2
    ;;
  *)
    exec umu-run "$target" "$@"
    ;;
esac
PROTON
chmod 0755 /usr/bin/raptor-wine-proton

# Desktop launches must not block Dolphin/Plasma while Wine creates its first
# prefix or UMU downloads its runtime/Proton distribution. Keep terminal use
# synchronous; these wrappers are only for file-manager/application launches.
cat <<'LAUNCH' > /usr/lib/raptor/launch-windows-app
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-wine}"
shift || true
if [[ $# -lt 1 || ! -f "$1" ]]; then
  echo "Raptor ${mode}: select an existing Windows executable." >&2
  command -v notify-send >/dev/null 2>&1 && notify-send --app-name="Raptor OS" "Windows app not started" "The selected executable could not be found."
  exit 2
fi
target="$1"
shift
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/raptor"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
stamp="$(date +%Y%m%d-%H%M%S)"
log="$state_dir/${mode}-${stamp}-$.log"
case "$mode" in
  wine) command=(/usr/bin/raptor-wine "$target" "$@"); label="Raptor Wine" ;;
  proton) command=(/usr/bin/raptor-wine-proton "$target" "$@"); label="Raptor Proton" ;;
  *) echo "Unknown Raptor compatibility mode: $mode" >&2; exit 2 ;;
esac
# Detach from the file manager. Capture every diagnostic and notify only if
# startup/application execution returns a failure status.
(
  set +e
  "${command[@]}" >>"$log" 2>&1
  status=$?
  if (( status != 0 )); then
    printf '\nRaptor launcher exit status: %s\n' "$status" >>"$log"
    if command -v notify-send >/dev/null 2>&1; then
      notify-send --app-name="Raptor OS" --urgency=critical "$label could not start" "Exit code $status. See $log"
    fi
  fi
) </dev/null >/dev/null 2>&1 &
exit 0
LAUNCH
chmod 0755 /usr/lib/raptor/launch-windows-app

cat <<'OPENWINE' > /usr/bin/raptor-wine-open
#!/usr/bin/env bash
exec /usr/lib/raptor/launch-windows-app wine "$@"
OPENWINE
cat <<'OPENPROTON' > /usr/bin/raptor-proton-open
#!/usr/bin/env bash
exec /usr/lib/raptor/launch-windows-app proton "$@"
OPENPROTON
chmod 0755 /usr/bin/raptor-wine-open /usr/bin/raptor-proton-open

cat <<'ASSOC' > /usr/bin/raptor-wine-associations
#!/usr/bin/env bash
set -euo pipefail
command -v xdg-mime >/dev/null 2>&1 || exit 0
# Repair stale Protontricks associations from earlier images, but preserve a
# different handler if the user deliberately chose one (for example Bottles).
for mime in \
  application/x-ms-dos-executable \
  application/vnd.microsoft.portable-executable \
  application/x-msdownload \
  application/x-msi; do
  current="$(xdg-mime query default "$mime" 2>/dev/null || true)"
  case "${current,,}" in
    ""|*protontricks*)
      xdg-mime default raptor-wine.desktop "$mime" >/dev/null 2>&1 || true
      ;;
  esac
done
command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
ASSOC
chmod 0755 /usr/bin/raptor-wine-associations

cat <<'UNIT' > /usr/lib/systemd/user/raptor-wine-associations.service
[Unit]
Description=Set Raptor Wine as the default Windows executable handler
After=plasma-plasmashell.service
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=/usr/bin/raptor-wine-associations

[Install]
WantedBy=graphical-session.target
UNIT

cat <<'DESKTOP' > /usr/share/applications/raptor-wine.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Open with Raptor Wine
GenericName=Windows program
Comment=Run Windows applications with standard Wine
Exec=raptor-wine-open %f
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
Exec=raptor-proton-open %f
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

for required in /usr/bin/raptor-wine /usr/bin/raptor-wine-proton /usr/bin/raptor-wine-open /usr/bin/raptor-proton-open /usr/lib/raptor/launch-windows-app /usr/bin/raptor-wine-associations /usr/lib/systemd/user/raptor-wine-associations.service /usr/share/applications/raptor-wine.desktop /usr/share/applications/raptor-wine-proton.desktop /usr/share/kio/servicemenus/raptor-wine.desktop; do
  [[ -s "$required" ]] || { echo "RAPTOR_WINE_PAYLOAD_MISSING:$required" >&2; exit 1; }
done
bash -n /usr/bin/raptor-wine
bash -n /usr/bin/raptor-wine-proton
bash -n /usr/lib/raptor/launch-windows-app
bash -n /usr/bin/raptor-wine-open
bash -n /usr/bin/raptor-proton-open
bash -n /usr/bin/raptor-wine-associations
echo "RAPTOR_WINE_READY: standard Wine workflow plus optional per-game Proton integration"
