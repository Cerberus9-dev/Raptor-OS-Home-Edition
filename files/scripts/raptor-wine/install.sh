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
Raptor Proton — Proton-powered Windows games and applications.

Usage:
  raptor-wine-proton program.exe [arguments...]

Raptor Proton uses UMU and the Steam Linux Runtime without requiring the
Steam client. Installed programs can be added to the KDE application menu.
HELP
  [[ $# -gt 0 ]] || exit 0
fi

command -v umu-run >/dev/null 2>&1 || {
  echo "Raptor Proton: UMU is not installed." >&2
  exit 1
}

export GAMEID="${RAPTOR_WINE_GAME_ID:-umu-default}"
export WINEPREFIX="${WINEPREFIX:-$HOME/Games/umu/umu-default}"
[[ -z "${RAPTOR_WINE_STORE:-}" ]] || export STORE="$RAPTOR_WINE_STORE"
[[ -z "${RAPTOR_WINE_PROTONPATH:-}" ]] || export PROTONPATH="$RAPTOR_WINE_PROTONPATH"

if [[ "${RAPTOR_WINE_DEBUG:-0}" == "1" ]]; then
  export UMU_LOG=1
  export PROTON_LOG=1
fi

target="${1:-}"
shift || true
[[ -n "$target" && -f "$target" ]] || {
  echo "Raptor Proton: select an existing Windows program." >&2
  exit 2
}

# UMU stores its Steam Linux Runtime in ~/.local/share/umu. Reuse the cached
# runtime between checks, but leave automatic updates enabled at least daily.
# The initial runtime and Proton downloads are still required on first launch.
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/raptor"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
runtime_stamp="$state_dir/umu-runtime-last-check"
now="$(date +%s)"
if [[ -d "$HOME/.local/share/umu" && -s "$runtime_stamp" ]]; then
  last="$(cat "$runtime_stamp" 2>/dev/null || true)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now >= last && now - last < 86400 )); then
    export UMU_RUNTIME_UPDATE=0
  else
    unset UMU_RUNTIME_UPDATE
  fi
else
  unset UMU_RUNTIME_UPDATE
fi

register_after="${RAPTOR_PROTON_REGISTER_AFTER:-0}"
marker=""
if [[ "$register_after" == "1" ]]; then
  marker="$(mktemp "${TMPDIR:-/tmp}/raptor-proton-before.XXXXXX")"
  touch "$marker"
fi

declare -a launch_command
case "${target,,}" in
  *.msi)
    # An empty UMU invocation initializes a prefix before Windows Installer runs.
    umu-run "" || exit $?
    msiexec="$WINEPREFIX/drive_c/windows/system32/msiexec.exe"
    [[ -f "$msiexec" ]] || {
      echo "Raptor Proton: Windows Installer was not created in the Proton prefix." >&2
      exit 1
    }
    launch_command=("$msiexec" /i "$target" "$@")
    ;;
  *)
    launch_command=("$target" "$@")
    ;;
esac

set +e
umu-run "${launch_command[@]}"
status=$?
set -e

if (( status == 0 )); then
  printf '%s\n' "$(date +%s)" > "$runtime_stamp"
  chmod 600 "$runtime_stamp"
  if [[ "$register_after" == "1" && -n "$marker" ]]; then
    /usr/bin/raptor-proton-register-apps "$WINEPREFIX" "$marker" || true
  fi
fi
[[ -z "$marker" ]] || rm -f "$marker"
exit "$status"
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
log="$state_dir/${mode}-${stamp}-$$.log"
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
      xdg-mime default raptor-wine-open.desktop "$mime" >/dev/null 2>&1 || true
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

cat <<'MANAGER' > /usr/bin/raptor-wine-manager
#!/usr/bin/env bash
set -euo pipefail
command -v kdialog >/dev/null 2>&1 || { echo 'KDialog is required.' >&2; exit 1; }
file="$(kdialog --getopenfilename "$HOME" 'Windows programs (*.exe *.msi *.com *.bat)' --title 'Choose a Windows program')" || exit 0
[[ -n "$file" ]] || exit 0
exec /usr/bin/raptor-wine-open "$file"
MANAGER
cat <<'MANAGER' > /usr/bin/raptor-proton-manager
#!/usr/bin/env bash
set -euo pipefail
command -v kdialog >/dev/null 2>&1 || { echo 'KDialog is required.' >&2; exit 1; }
file="$(kdialog --getopenfilename "$HOME" 'Windows programs (*.exe *.com *.bat)' --title 'Choose a Windows game or program')" || exit 0
[[ -n "$file" ]] || exit 0
exec /usr/bin/raptor-proton-open "$file"
MANAGER
cat <<'PREFIX' > /usr/bin/raptor-proton-prefix-manager
#!/usr/bin/env bash
set -euo pipefail
command -v kdialog >/dev/null 2>&1 || { echo 'KDialog is required.' >&2; exit 1; }
command -v protontricks-launch >/dev/null 2>&1 || { kdialog --error 'Protontricks launcher is not installed.'; exit 1; }
declare -a ids=()
declare -A roots=()
for root in "$HOME/.steam/steam/steamapps/compatdata" "$HOME/.local/share/Steam/steamapps/compatdata"; do
  [[ -d "$root" ]] || continue
  for prefix in "$root"/*/pfx; do
    [[ -d "$prefix" ]] || continue
    id="$(basename "$(dirname "$prefix")")"
    if [[ -z "${roots[$id]:-}" ]]; then ids+=("$id"); roots[$id]="$prefix"; fi
  done
done
((${#ids[@]} > 0)) || { kdialog --msgbox 'No Steam/Proton prefixes were found.'; exit 0; }
choice="$(kdialog --combobox 'Choose the Steam/Proton prefix:' "${ids[@]}" --title 'Raptor Proton — choose prefix')" || exit 0
[[ -n "$choice" ]] || exit 0
prefix="${roots[$choice]}"
exe="$(kdialog --getopenfilename "$prefix/drive_c" 'Windows programs (*.exe)' --title 'Choose installed program')" || exit 0
[[ -n "$exe" && -f "$exe" ]] || exit 0
name="$(kdialog --inputbox 'Name shown in the application launcher:' "$(basename "$exe" .exe)")" || exit 0
[[ -n "$name" ]] || exit 0
safe="$(printf '%s' "$name" | tr -cd '[:alnum:] _.-' | sed 's/[[:space:]]\+/-/g')"
dir="$HOME/.local/share/applications/raptor-proton-apps"
mkdir -p "$dir"
desktop="$dir/raptor-proton-$choice-$safe.desktop"
cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.1
Name=$name
Comment=Launch $name from Steam/Proton prefix $choice
Exec=/usr/bin/raptor-proton-prefix-open $choice "$exe"
Icon=applications-games
Terminal=false
Categories=Game;Utility;
EOF
chmod 0644 "$desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$dir" >/dev/null 2>&1 || true
command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
kdialog --msgbox "Added $name to the application launcher."
PREFIX
cat <<'PREFIXOPEN' > /usr/bin/raptor-proton-prefix-open
#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 2 ]] || { echo 'Usage: raptor-proton-prefix-open STEAM_APP_ID executable.exe [args...]' >&2; exit 2; }
appid="$1"; shift
[[ "$appid" =~ ^[0-9]+$ ]] || { echo 'Invalid Steam app ID.' >&2; exit 2; }
exec protontricks-launch --appid "$appid" "$@"
PREFIXOPEN
chmod 0755 /usr/bin/raptor-proton-prefix-manager /usr/bin/raptor-proton-prefix-open
chmod 0755 /usr/bin/raptor-wine-manager /usr/bin/raptor-proton-manager
cat <<'DESKTOP' > /usr/share/applications/raptor-wine-manager.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Raptor Wine
GenericName=Windows application compatibility
Comment=Choose and run a Windows application with Wine
Exec=raptor-wine-manager
Icon=application-x-ms-dos-executable
Terminal=false
Categories=System;Utility;
DESKTOP
cat <<'PROTONDESKTOP' > /usr/share/applications/raptor-proton-manager.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Raptor Proton
GenericName=Windows game compatibility
Comment=Choose and run a Windows game with Proton
Exec=raptor-proton-manager
Icon=applications-games
Terminal=false
Categories=Game;Utility;
PROTONDESKTOP
cat <<'PREFIXDESKTOP' > /usr/share/applications/raptor-proton-prefix-manager.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Raptor Proton Prefix Apps
GenericName=Installed Windows applications
Comment=Add a program installed in a Steam/Proton prefix to application search
Exec=raptor-proton-prefix-manager
Icon=applications-games
Terminal=false
Categories=Game;Utility;
PREFIXDESKTOP
cat <<'OPENHANDLER' > /usr/share/applications/raptor-wine-open.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Open with Raptor Wine
Exec=raptor-wine-open %f
Icon=application-x-ms-dos-executable
Terminal=false
NoDisplay=true
MimeType=application/x-ms-dos-executable;application/x-msi;application/vnd.microsoft.portable-executable;application/x-msdownload;
OPENHANDLER
cat <<'PROTONHANDLER' > /usr/share/applications/raptor-proton-open.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Run with Raptor Proton
Exec=raptor-proton-open %f
Icon=applications-games
Terminal=false
NoDisplay=true
PROTONHANDLER
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
Exec=raptor-wine-open %f

[Desktop Action raptorProtonRun]
Name=Run with Raptor Proton (games)
Icon=applications-games
Exec=raptor-proton-open %f
SERVICE

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

for required in /usr/bin/raptor-wine /usr/bin/raptor-wine-proton /usr/bin/raptor-wine-open /usr/bin/raptor-proton-open /usr/bin/raptor-proton-prefix-manager /usr/bin/raptor-proton-prefix-open /usr/lib/raptor/launch-windows-app /usr/bin/raptor-wine-associations /usr/lib/systemd/user/raptor-wine-associations.service /usr/share/applications/raptor-wine-manager.desktop /usr/share/applications/raptor-proton-manager.desktop /usr/share/applications/raptor-proton-prefix-manager.desktop /usr/share/applications/raptor-wine-open.desktop /usr/share/applications/raptor-proton-open.desktop /usr/share/kio/servicemenus/raptor-wine.desktop; do
  [[ -s "$required" ]] || { echo "RAPTOR_WINE_PAYLOAD_MISSING:$required" >&2; exit 1; }
done
bash -n /usr/bin/raptor-wine
bash -n /usr/bin/raptor-wine-proton
bash -n /usr/lib/raptor/launch-windows-app
bash -n /usr/bin/raptor-wine-open
bash -n /usr/bin/raptor-proton-open
bash -n /usr/bin/raptor-wine-associations
bash -n /usr/bin/raptor-wine-manager
bash -n /usr/bin/raptor-proton-manager
bash -n /usr/bin/raptor-proton-prefix-manager
bash -n /usr/bin/raptor-proton-prefix-open
echo "RAPTOR_WINE_READY: standard Wine workflow plus optional per-game Proton integration"
