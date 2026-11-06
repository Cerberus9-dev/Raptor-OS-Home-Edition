#!/bin/bash
set -euo pipefail

# Raptor Wine deliberately behaves like ordinary Wine.
# The system Wine binaries and their normal CLI/prefix behavior are preserved.
# UMU/Proton is available as an optional game runner, never forced on users.

command -v wine >/dev/null 2>&1 || {
  echo "RAPTOR_WINE_ERROR: system Wine is not installed" >&2
  exit 1
}
command -v umu-run >/dev/null 2>&1 || {
  echo "RAPTOR_WINE_ERROR: umu-run is not installed" >&2
  exit 1
}

cat <<'PROTON' > /usr/bin/raptor-wine-proton
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then
  cat <<'HELP'
Optional Proton runner for Windows games (Steam client not required).

Usage:
  raptor-wine-proton game.exe [arguments...]

Ordinary Windows applications should be launched with:
  wine program.exe

This command is intentionally separate. It uses UMU to provide Proton's
expected Steam Linux Runtime without opening or requiring the Steam client.
HELP
  [[ $# -gt 0 ]] || exit 2
  exit 0
fi

command -v umu-run >/dev/null 2>&1 || {
  echo "raptor-wine-proton: UMU is not installed." >&2
  exit 1
}

# UMU chooses and maintains its normal game prefix/runtime. No custom prefix
# manager, storefront setup, or per-application configuration is required.
export GAMEID="${RAPTOR_WINE_GAME_ID:-umu-default}"
if [[ -n "${RAPTOR_WINE_PROTONPATH:-}" ]]; then
  export PROTONPATH="$RAPTOR_WINE_PROTONPATH"
fi
exec umu-run "$@"
PROTON
chmod 0755 /usr/bin/raptor-wine-proton

cat <<'DESKTOP' > /usr/share/applications/raptor-wine.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Open with Raptor Wine
GenericName=Windows program
Comment=Run a Windows program with the normal Wine command
Exec=wine %f
Icon=application-x-ms-dos-executable
Terminal=false
NoDisplay=true
MimeType=application/x-ms-dos-executable;application/x-msi;application/vnd.microsoft.portable-executable;application/x-msdownload;
DESKTOP

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

[[ -x /usr/bin/raptor-wine-proton ]] || {
  echo "RAPTOR_WINE_PAYLOAD_MISSING:/usr/bin/raptor-wine-proton" >&2
  exit 1
}
bash -n /usr/bin/raptor-wine-proton
echo "RAPTOR_WINE_READY: standard Wine CLI preserved; optional UMU/Proton runner installed"
