#!/bin/bash
set -e

# =============================================================================
# Raptor OS — Wine application launcher
# Managed Wine prefixes with auto-bootstrapped runtimes.
#
# WHY: double-clicking a Windows .exe in Dolphin used to fall into an
# unconfigured ~/.wine prefix. First run never installed the MSVC++ runtime
# DLLs that most "regular" Windows apps (installers, office tools, utilities)
# require, so they crashed immediately or misbehaved — which is why games and
# apps kept having to be forced through Steam/Proton instead.
#
# raptor-wine gives you:
#   * a dedicated, managed prefix (default: ~/.local/share/raptor-wine/default)
#   * first-run bootstrap: wineboot + silent install of vcrun2015, vcrun2019
#     and corefonts via winetricks (best-effort — deferred not fatal if the
#     download stalls, and retried on the next launch)
#   * `--prefix NAME` for isolated prefixes, `--reset` for a clean slate
#   * MIME + Dolphin right-click integration for .exe/.msi
# =============================================================================

# ── Windows app launcher ────────────────────────────────────────────────────
cat << 'EOF' > /usr/bin/raptor-wine
#!/bin/bash
# raptor-wine — launch Windows apps with a managed, bootstrapped Wine prefix.
set -euo pipefail

DATA_DIR="$HOME/.local/share/raptor-wine"
DEFAULT_RUNTIMES="vcrun2015 vcrun2019 corefonts d3dcompiler_47 dxvk"
RUNTIME_LOG="$DATA_DIR/runtimes.log"
WINETRICKS_CACHE="$HOME/.cache/winetricks"

usage() {
    cat <<'HELP'
Usage: raptor-wine [OPTIONS] <program.exe|program.msi>

Run a Windows application with a managed Wine prefix. On first use the prefix
is initialised and the common MSVC++ runtime DLLs / fonts are installed
silently (best-effort; deferred if the download stalls, retried next launch).

Options:
  --prefix NAME        Use a dedicated prefix ~/.local/share/raptor-wine/NAME
                       (default "default"). Keeps incompatible apps apart.
  --reset              Delete the prefix first, then (re)launch <program>.
  --install-runtime R  Install one winetricks runtime (e.g. dotnet48,
                       vcrun2013, mf) into the prefix and exit.
  --no-bootstrap       Skip prefix init + runtime install entirely.
  -h, --help           Show this help.
HELP
}

PREFIX_NAME="default"
RESET=0
INSTALL_RUNTIME=""
BOOTSTRAP=1

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)         PREFIX_NAME="${2:-}"; shift 2 ;;
        --reset)          RESET=1; shift ;;
        --install-runtime) INSTALL_RUNTIME="${2:-}"; shift 2 ;;
        --no-bootstrap)   BOOTSTRAP=0; shift ;;
        -h|--help)        usage; exit 0 ;;
        -*) echo "raptor-wine: unknown option $1" >&2; usage; exit 2 ;;
        *) break ;;
    esac
done

[ -n "$PREFIX_NAME" ] || { echo "raptor-wine: --prefix needs a name" >&2; exit 2; }
case "$PREFIX_NAME" in
    *[!A-Za-z0-9._-]*|"") echo "raptor-wine: invalid prefix name '$PREFIX_NAME'" >&2; exit 2 ;;
esac

if [ -z "$INSTALL_RUNTIME" ] && [ $# -lt 1 ]; then
    usage
    exit 2
fi

: "${WINE:=wine}"

CMD_WINE="$WINE"
case "$CMD_WINE" in
    */*) ;;
    *) CMD_WINE="$(command -v "$WINE" 2>/dev/null || echo wine)" ;;
esac
command -v wineboot >/dev/null 2>&1 || { echo "raptor-wine: wine not installed" >&2; exit 1; }

PREFIX_PATH="$DATA_DIR/$PREFIX_NAME"
export WINEPREFIX="$PREFIX_PATH"
export WINEDEBUG="${WINEDEBUG:--all}"
mkdir -p "$DATA_DIR"

if [ "$RESET" = 1 ]; then
    "$CMD_WINE" wineserver -k >/dev/null 2>&1 || true
    rm -rf "$PREFIX_PATH"
    rm -f "$DATA_DIR/$PREFIX_NAME.runtimes-done"
    echo "raptor-wine: prefix '$PREFIX_NAME' wiped."
fi

# ── First-run bootstrap ──────────────────────────────────────────────────────
if [ "$BOOTSTRAP" = 1 ] && [ ! -f "$PREFIX_PATH/system.reg" ]; then
    echo "raptor-wine: initialising new prefix '$PREFIX_NAME' (one-time)…"
    mkdir -p "$PREFIX_PATH"
    wineboot >/dev/null 2>&1 || wineboot -u >/dev/null 2>&1 || true

    # Install Wine Mono + Gecko for .NET/JavaScript apps (if available)
    if command -v wine-mono-installer >/dev/null 2>&1; then
        wine-mono-installer --prefix "$PREFIX_PATH" >/dev/null 2>&1 || true
    fi
    if command -v wine-gecko-installer >/dev/null 2>&1; then
        wine-gecko-installer --prefix "$PREFIX_PATH" >/dev/null 2>&1 || true
    fi
fi

# Ensure winetricks cache directory exists
mkdir -p "$WINETRICKS_CACHE"

# ── Best-effort runtime install ─────────────────────────────────────────────
STAMP="$DATA_DIR/$PREFIX_NAME.runtimes-done"
if [ -n "$INSTALL_RUNTIME" ]; then
    if winetricks --unattended --quiet "$INSTALL_RUNTIME" >&2; then
        case " $DEFAULT_RUNTIMES " in
            *" $INSTALL_RUNTIME "*) touch "$STAMP" ;;
        esac
        echo "raptor-wine: runtime '$INSTALL_RUNTIME' installed."
        exit 0
    else
        echo "raptor-wine: installing '$INSTALL_RUNTIME' failed — check the network." >&2
        echo "raptor-wine: on flaky connections retry; winetricks resumes from cache." >&2
        exit 1
    fi
fi

if [ "$BOOTSTRAP" = 1 ] && [ ! -f "$STAMP" ]; then
    echo "raptor-wine: installing common Windows runtimes (one-time, may take a while)…"
    if winetricks --unattended --quiet $DEFAULT_RUNTIMES >>"$RUNTIME_LOG" 2>&1; then
        touch "$STAMP"
        echo "raptor-wine: common runtimes installed."
    else
        echo "raptor-wine: runtime install deferred (download issue) — apps that need" >&2
        echo "raptor-wine: MSVC runtime DLLs may fail until they're present. Retry with:" >&2
        echo "raptor-wine:   raptor-wine --install-runtime vcrun2015" >&2
        echo "raptor-wine:   raptor-wine --install-runtime vcrun2019" >&2
    fi
fi

# ── DXVK/VKD3D setup for the prefix ──────────────────────────────────────────
# DXVK is installed via winetricks above; ensure the override is registered
if [ "$BOOTSTRAP" = 1 ] && [ -f "$STAMP" ]; then
    # The dxvk runtime installs d3d9, d3d10core, d3d11, dxgi overrides
    # They should be set to native by winetricks, but verify:
    "$CMD_WINE" reg add "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides" \
        /v "d3d9" /t REG_SZ /d "native" /f >/dev/null 2>&1 || true
    "$CMD_WINE" reg add "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides" \
        /v "d3d10core" /t REG_SZ /d "native" /f >/dev/null 2>&1 || true
    "$CMD_WINE" reg add "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides" \
        /v "d3d11" /t REG_SZ /d "native" /f >/dev/null 2>&1 || true
    "$CMD_WINE" reg add "HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides" \
        /v "dxgi" /t REG_SZ /d "native" /f >/dev/null 2>&1 || true
fi

# ── Environment hardening ───────────────────────────────────────────────────
# esync/fsync for better performance with esync-heavy games
export WINEESYNC="${WINEESYNC:-1}"
export WINEFSYNC="${WINEFSYNC:-1}"

# Disable winemenubuilder to prevent polluting the app menu
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-winemenubuilder.exe=d}"

# Force VA-API for hardware video decode
export VKD3D_CONFIG="${VKD3D_CONFIG:-dxr11}"

# ── ProtonUp-Qt integration ─────────────────────────────────────────────────
# If the user has ProtonUp-Qt installed, we can use its Proton builds
PROTONUP_DIR="$HOME/.local/share/protonup-qt/proton-ge-custom"
if [ -d "$PROTONUP_DIR" ]; then
    LATEST_PROTON=$(ls -1 "$PROTONUP_DIR" 2>/dev/null | sort -V | tail -1)
    if [ -n "$LATEST_PROTON" ]; then
        export STEAM_COMPAT_DATA_PATH="${STEAM_COMPAT_DATA_PATH:-$DATA_DIR/$PREFIX_NAME}"
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}"
        export WINEDLLOVERRIDES="${WINEDLLOVERRIDES};winemenubuilder.exe=d"
    fi
fi

# ── Launch ──────────────────────────────────────────────────────────────────
case "$1" in
    *.msi|*.MSI) exec "$CMD_WINE" msiexec /i "$@" ;;
    *)           exec "$CMD_WINE" "$@" ;;
esac
EOF
chmod 755 /usr/bin/raptor-wine

# ── .desktop + MIME binding (double-click in Dolphin) ─────────────────────────
cat << 'EOF' > /usr/share/applications/raptor-wine.desktop
[Desktop Entry]
Type=Application
Version=1.1
Name=Windows Application (Raptor Wine)
GenericName=Launch Windows app
Comment=Run a Windows .exe/.msi in a managed Raptor Wine prefix
Exec=raptor-wine %U
Icon=application-x-ms-dos-executable
Terminal=false
Categories=X-RaptorOS;System;Utility;
MimeType=application/x-ms-dos-executable;application/x-msi;application/vnd.microsoft.portable-executable;application/x-msdownload;
Keywords=wine;windows;exe;msi;proton;application;
NoDisplay=true
EOF

# ── Dolphin right-click servicemenu ─────────────────────────────────────────
mkdir -p /usr/share/kio/servicemenus
cat << 'EOF' > /usr/share/kio/servicemenus/raptor-wine.desktop
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
EOF

# Refresh app / MIME caches so the new handlers show up immediately.
update-desktop-database /usr/share/applications >/dev/null 2>&1 || true

# ── Self-check ────────────────────────────────────────────────────────────────
# A malformed heredoc here can install a truncated binary or a missing .desktop
# entry, and Wine then never appears in the launcher with an empty build log.
# Verify each artifact landed and is non-empty; fail the build if not.
RAPTOR_EXPECTED_PAYLOAD="
/usr/bin/raptor-wine
/usr/share/applications/raptor-wine.desktop
/usr/share/kio/servicemenus/raptor-wine.desktop
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "RAPTOR_WINE_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
echo "RAPTOR_WINE_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"