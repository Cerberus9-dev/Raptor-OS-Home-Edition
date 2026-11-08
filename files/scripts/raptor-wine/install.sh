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
export WINEPREFIX="${WINEPREFIX:-$HOME/Games/umu/$GAMEID}"
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
target="$(realpath -e -- "$target")"
target_dir="$(dirname "$target")"
target_name="$(basename "$target")"
# UMU 1.4 has a reported path-handling regression for absolute EXE paths.
# Launch from the executable directory with a relative target, and explicitly
# expose non-home locations to pressure-vessel for removable/external drives.
case "$target_dir/" in
  "$HOME/"*) ;;
  *)
    export STEAM_COMPAT_LIBRARY_PATHS="${STEAM_COMPAT_LIBRARY_PATHS:+$STEAM_COMPAT_LIBRARY_PATHS:}$target_dir"
    ;;
esac
cd "$target_dir"
target="./$target_name"

# UMU stores its Steam Linux Runtime in ~/.local/share/umu. Reuse the cached
# runtime between checks, but leave automatic updates enabled at least daily.
# The initial runtime and Proton downloads are still required on first launch.
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/raptor"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
runtime_stamp="$state_dir/umu-runtime-last-check"
now="$(date +%s)"
runtime_is_fresh=0
if [[ -d "$HOME/.local/share/umu" && -s "$runtime_stamp" ]]; then
  last="$(cat "$runtime_stamp" 2>/dev/null || true)"
  if [[ "$last" =~ ^[0-9]+$ ]] && (( now >= last && now - last < 86400 )); then
    runtime_is_fresh=1
  fi
fi

if (( runtime_is_fresh )); then
  export UMU_RUNTIME_UPDATE=0
else
  # UMU's documented empty-executable form creates/updates its prefix without
  # launching an app. Do this once per day, before any game/installer, so a
  # game that exits with a non-zero code does not force a slow runtime check
  # again on its next launch.
  echo "Raptor Proton: preparing its compatibility runtime (first launch or daily check)…"
  if ! umu-run ""; then
    echo "Raptor Proton: runtime preparation failed. Check the UMU log and network connection." >&2
    exit 1
  fi
  printf '%s\n' "$(date +%s)" > "$runtime_stamp"
  chmod 600 "$runtime_stamp"
  export UMU_RUNTIME_UPDATE=0
fi

register_after="${RAPTOR_PROTON_REGISTER_AFTER:-0}"
marker=""
if [[ "$register_after" == "1" ]]; then
  marker="$(mktemp "${TMPDIR:-/tmp}/raptor-proton-before.XXXXXX")"
  if [[ -d "$WINEPREFIX/drive_c" ]]; then
    find "$WINEPREFIX/drive_c" -type f -iname '*.exe' \
      ! -path "$WINEPREFIX/drive_c/windows/*" -print0 2>/dev/null | sort -z > "$marker"
  fi
fi

declare -a launch_command
case "${target,,}" in
  *.msi)
    # The common preflight above has already initialized the default prefix.
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

# UMU/Wine can leave an idle wineserver behind after the last app exits.
# Reclaim that memory only when no other process for this exact prefix remains;
# this deliberately preserves concurrently running apps that share a prefix.
cleanup_idle_wineserver() {
  command -v wineserver >/dev/null 2>&1 || return 0
  local proc pid comm
  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ "$pid" == "$" || "$pid" == "$PPID" ]] && continue
    [[ -r "$proc/environ" ]] || continue
    comm=""
    [[ -r "$proc/comm" ]] && IFS= read -r comm < "$proc/comm" || true
    [[ "$comm" == "wineserver" ]] && continue
    if tr '\0' '\n' < "$proc/environ" 2>/dev/null | grep -Fqx "WINEPREFIX=$WINEPREFIX"; then
      return 0
    fi
  done
  WINEPREFIX="$WINEPREFIX" wineserver -k >/dev/null 2>&1 || true
}
cleanup_idle_wineserver

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

cat <<'REGISTER' > /usr/bin/raptor-proton-register-apps
#!/usr/bin/env bash
set -euo pipefail

prefix="${1:-}"
mode="${2:-}"
[[ -d "$prefix/drive_c" ]] || exit 0
command -v zenity >/dev/null 2>&1 || exit 0

exe=""
if [[ "$mode" == "--manual" ]]; then
  start_dir="$prefix/drive_c/Program Files"
  [[ -d "$start_dir" ]] || start_dir="$prefix/drive_c"
  exe="$(zenity --file-selection --title="Add an installed app to KDE" \
    --filename="$start_dir/" \
    --file-filter="Windows applications | *.exe" 2>/dev/null)" || exit 0
  [[ -n "$exe" && -f "$exe" ]] || exit 0
else
  [[ -n "$mode" && -f "$mode" ]] || exit 0
  declare -a rows=()
  count=0
  while IFS= read -r -d '' candidate; do
    lower="${candidate,,}"
    case "$lower" in
      */windows/*|*/windows|*/unins*.exe|*/uninstall*.exe|*/setup*.exe|*/update*.exe|*/vcredist*.exe|*/dxsetup.exe|*/crash*.exe|*/redist*.exe)
        continue ;;
    esac
    name="$(basename "$candidate")"
    name="${name%.[eE][xX][eE]}"
    rows+=("$name" "$candidate")
    ((count+=1))
    (( count >= 50 )) && break
  # Installers sometimes preserve the original executable timestamps, so do not
  # depend on mtime. Search app locations outside the Windows system directory.
  # Compare against the pre-install snapshot, rather than mtimes: many
  # installers unpack EXEs with preserved timestamps and would be missed.
  done < <(comm -z -13 "$mode" <(find "$prefix/drive_c" -type f -iname '*.exe' -size +128k \
      ! -path "$prefix/drive_c/windows/*" -print0 2>/dev/null | sort -z))
  (("${#rows[@]}" > 0)) || exit 0
  exe="$(zenity --list --title="Raptor Proton — Add to KDE" \
    --text="Choose the application installed by the program you just ran." \
    --column="Application" --column="Executable" --hide-column=2 --print-column=2 \
    "${rows[@]}" 2>/dev/null)" || exit 0
  [[ -n "$exe" && -f "$exe" ]] || exit 0
fi

default_name="$(basename "$exe")"
default_name="${default_name%.[eE][xX][eE]}"
app_name="$(zenity --entry --title="Raptor Proton — Application name" \
  --text="Name to show in the KDE application menu:" --entry-text="$default_name" 2>/dev/null)" || exit 0
[[ -n "$app_name" ]] || exit 0

category="$(zenity --list --radiolist --title="Raptor Proton — Application category" \
  --text="Choose where this application belongs in the KDE menu." \
  --column="" --column="Menu section" TRUE "Game" FALSE "Utility" 2>/dev/null)" || exit 0
[[ "$category" == "Game" || "$category" == "Utility" ]] || exit 0

desktop_dir="$HOME/.local/share/applications/raptor-proton-apps"
mkdir -p "$desktop_dir"
python3 - "$desktop_dir" "$app_name" "$prefix" "$exe" "$category" <<'PY'
import hashlib
import os
import re
import sys

directory, name, prefix, executable, category = sys.argv[1:]
def key_escape(value):
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "")
def exec_quote(value):
    value = value.replace("\\", "\\\\").replace('"', '\\"')
    value = value.replace("$", "\\$")
    value = value.replace("%", "%%")
    return '"' + value + '"'

slug = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "application"
digest = hashlib.sha256((prefix + "\0" + executable).encode()).hexdigest()[:10]
path = os.path.join(directory, "raptor-proton-" + slug[:48] + "-" + digest + ".desktop")
icon = "applications-games" if category == "Game" else "application-x-executable"
body = "\n".join([
    "[Desktop Entry]",
    "Type=Application",
    "Version=1.1",
    "Name=" + key_escape(name),
    "Comment=Launch " + key_escape(name) + " with Raptor Proton",
    "Exec=/usr/bin/raptor-proton-launch-installed " + exec_quote(prefix) + " " + exec_quote(executable),
    "TryExec=/usr/bin/raptor-proton-launch-installed",
    "Icon=" + icon,
    "Terminal=false",
    "StartupNotify=false",
    "Categories=" + category + ";",
    "",
])
with open(path, "w", encoding="utf-8") as stream:
    stream.write(body)
os.chmod(path, 0o644)
print(path)
PY
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$desktop_dir" >/dev/null 2>&1 || true
# Refresh the KDE application cache in the background rather than blocking the installer.
if command -v kbuildsycoca6 >/dev/null 2>&1; then
  kbuildsycoca6 --noincremental >/dev/null 2>&1 &
fi
command -v notify-send >/dev/null 2>&1 && notify-send --app-name="Raptor Proton" \
  "Added to KDE applications" "$app_name is now listed under $category."
REGISTER
chmod 0755 /usr/bin/raptor-proton-register-apps

cat <<'PREFIXLAUNCH' > /usr/bin/raptor-proton-launch-installed
#!/usr/bin/env bash
set -euo pipefail
[[ $# -ge 2 ]] || exit 2
prefix="$1"; shift
target="$1"; shift
[[ -d "$prefix/drive_c" && -f "$target" ]] || {
  command -v notify-send >/dev/null 2>&1 && notify-send --app-name="Raptor Proton" \
    "Application not found" "The installed program or its Proton prefix is missing."
  exit 2
}
export WINEPREFIX="$prefix"
export RAPTOR_WINE_GAME_ID="${RAPTOR_WINE_GAME_ID:-umu-default}"
exec /usr/bin/raptor-wine-proton "$target" "$@"
PREFIXLAUNCH
chmod 0755 /usr/bin/raptor-proton-launch-installed

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
# Detach from the file manager and show immediate feedback. First-time prefix
# creation and UMU runtime preparation can take longer than an ordinary launch.
if command -v notify-send >/dev/null 2>&1; then
  notify-send --app-name="Raptor OS" --icon=applications-games "$label" \
    "Starting the Windows application. First-time compatibility setup may take longer."
fi
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
set -euo pipefail
if [[ $# -eq 0 ]]; then
  exec /usr/bin/raptor-wine-manager
fi
exec /usr/lib/raptor/launch-windows-app wine "$@"
OPENWINE
cat <<'OPENPROTON' > /usr/bin/raptor-proton-open
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 0 ]]; then
  exec /usr/bin/raptor-proton-manager
fi
if [[ -z "${RAPTOR_PROTON_REGISTER_AFTER+x}" ]]; then
  case "${1,,}" in
    *.msi|*setup*.exe|*install*.exe|*installer*.exe|*bootstrap*.exe)
      export RAPTOR_PROTON_REGISTER_AFTER=1 ;;
    *)
      export RAPTOR_PROTON_REGISTER_AFTER=0 ;;
  esac
fi
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

if command -v kdialog >/dev/null 2>&1; then
  file="$(kdialog --title="Raptor Wine" --getopenfilename "$HOME" \
    "Windows programs (*.exe *.msi *.com *.bat)")" || exit 0
elif command -v zenity >/dev/null 2>&1; then
  file="$(zenity --file-selection --title="Raptor Wine — Choose a Windows program" \
    --file-filter="Windows programs | *.exe *.msi *.com *.bat")" || exit 0
else
  command -v notify-send >/dev/null 2>&1 && notify-send --app-name="Raptor OS" \
    "Raptor Wine unavailable" "A graphical file chooser is not available."
  exit 1
fi
[[ -n "$file" && -f "$file" ]] || exit 0
exec /usr/bin/raptor-wine-open "$file"
MANAGER
cat <<'MANAGER' > /usr/bin/raptor-proton-manager
#!/usr/bin/env bash
set -euo pipefail
prefix="\${WINEPREFIX:-$HOME/Games/umu/umu-default}"

if command -v kdialog >/dev/null 2>&1; then
  action="$(kdialog --title="Raptor Proton" --menu="Choose an action" \
    launch "Launch a Windows app or game" \
    install "Install a Windows application" \
    register "Add an installed app to the KDE menu")" || exit 0
else
  action="$(zenity --list --radiolist --title="Raptor Proton" \
    --text="Choose what you want to do." \
    --column="" --column="Action" TRUE "Launch" FALSE "Install" FALSE "Add installed app" \
    2>/dev/null)" || exit 0
  case "$action" in
    Launch) action="launch" ;;
    Install) action="install" ;;
    "Add installed app") action="register" ;;
    *) exit 0 ;;
  esac
fi

if [[ "$action" == "register" ]]; then
  exec /usr/bin/raptor-proton-register-apps "$prefix" --manual
fi

if command -v kdialog >/dev/null 2>&1; then
  file="$(kdialog --title="Raptor Proton" --getopenfilename "$HOME" \
    "Windows programs (*.exe *.msi *.com *.bat)")" || exit 0
else
  file="$(zenity --file-selection --title="Raptor Proton — Choose a Windows program" \
    --file-filter="Windows programs | *.exe *.msi *.com *.bat")" || exit 0
fi
[[ -n "$file" && -f "$file" ]] || exit 0

if [[ "$action" == "install" ]]; then
  export RAPTOR_PROTON_REGISTER_AFTER=1
else
  export RAPTOR_PROTON_REGISTER_AFTER=0
fi
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
Categories=Game;
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
Categories=Game;
PREFIXDESKTOP
cat <<'OPENHANDLER' > /usr/share/applications/raptor-wine-open.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Raptor Wine
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
Name=Raptor Proton
Exec=raptor-proton-open %f
Icon=applications-games
Terminal=false
NoDisplay=true
MimeType=application/x-ms-dos-executable;application/vnd.microsoft.portable-executable;application/x-msdownload;application/x-msi;
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
Name=Raptor Wine
Icon=application-x-ms-dos-executable
Exec=raptor-wine-open %f

[Desktop Action raptorProtonRun]
Name=Raptor Proton
Icon=applications-games
Exec=raptor-proton-open %f
SERVICE

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

for required in /usr/bin/raptor-wine /usr/bin/raptor-wine-proton /usr/bin/raptor-wine-open /usr/bin/raptor-proton-open /usr/bin/raptor-proton-register-apps /usr/bin/raptor-proton-launch-installed /usr/bin/raptor-proton-prefix-manager /usr/bin/raptor-proton-prefix-open /usr/lib/raptor/launch-windows-app /usr/bin/raptor-wine-associations /usr/lib/systemd/user/raptor-wine-associations.service /usr/share/applications/raptor-wine-manager.desktop /usr/share/applications/raptor-proton-manager.desktop /usr/share/applications/raptor-proton-prefix-manager.desktop /usr/share/applications/raptor-wine-open.desktop /usr/share/applications/raptor-proton-open.desktop /usr/share/kio/servicemenus/raptor-wine.desktop; do
  [[ -s "$required" ]] || { echo "RAPTOR_WINE_PAYLOAD_MISSING:$required" >&2; exit 1; }
done
bash -n /usr/bin/raptor-wine
bash -n /usr/bin/raptor-wine-proton
bash -n /usr/lib/raptor/launch-windows-app
bash -n /usr/bin/raptor-wine-open
bash -n /usr/bin/raptor-proton-open
bash -n /usr/bin/raptor-proton-register-apps
bash -n /usr/bin/raptor-proton-launch-installed
bash -n /usr/bin/raptor-wine-associations
bash -n /usr/bin/raptor-wine-manager
bash -n /usr/bin/raptor-proton-manager
bash -n /usr/bin/raptor-proton-prefix-manager
bash -n /usr/bin/raptor-proton-prefix-open
echo "RAPTOR_WINE_READY: Wine plus UMU/Proton, installer registration and KDE application launchers"
