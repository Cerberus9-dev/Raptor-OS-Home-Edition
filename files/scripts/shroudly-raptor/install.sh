#!/usr/bin/env bash
set -euo pipefail

# Raptor Shroudly installer
# - Ships the upstream Shroudly Electron desktop app (engine + UI) as the
#   functional core, with proper credit.
# - Adds Raptor OS branding, desktop integration, and a reliable payload
#   install path that survives BlueBuild's files module.
#
# The separate Rust/Slint "Raptor Shroudly" dashboard (crates/shroudly-raptor)
# remains available for future native routing / game-mode work. This script
# does not remove or replace that crate.

STAGE_DIR="/tmp/raptor-staging"
if [[ ! -d "$STAGE_DIR/raptor-shroudly-app" && ! -f "$STAGE_DIR/raptor-shroudly-app.tar.gz" ]]; then
    if [[ -d "/tmp/files/staging/raptor-shroudly-app" || -f "/tmp/files/staging/raptor-shroudly-app.tar.gz" ]]; then
        STAGE_DIR="/tmp/files/staging"
    fi
fi

STAGED_BIN="$STAGE_DIR/raptor-shroudly"
STAGED_APP="$STAGE_DIR/raptor-shroudly-app"
STAGED_APP_TAR="$STAGE_DIR/raptor-shroudly-app.tar.gz"
STAGED_ICON="$STAGE_DIR/raptor-shroudly-icon.png"
STAGED_LICENSE="$STAGE_DIR/raptor-shroudly-license"
STAGED_POLICY="$STAGE_DIR/raptor-shroudly-policy"
STAGED_NOTICE="$STAGE_DIR/raptor-shroudly-notice"

# --- Required payload checks -------------------------------------------------
for required in "$STAGED_BIN" "$STAGED_ICON" "$STAGED_LICENSE" "$STAGED_POLICY"; do
    [[ -s "$required" ]] || {
        echo "RAPTOR_SHROUDLY_PAYLOAD_MISSING:$required" >&2
        exit 1
    }
done
[[ -x "$STAGED_BIN" ]] || {
    echo "RAPTOR_SHROUDLY_LAUNCHER_NOT_EXECUTABLE" >&2
    exit 1
}

# Prefer the single-file tarball (reliable). Fall back to directory tree.
if [[ -s "$STAGED_APP_TAR" ]]; then
    PAYLOAD_MODE=tar
elif [[ -d "$STAGED_APP" && -s "$STAGED_APP/resources/app.asar" ]]; then
    PAYLOAD_MODE=dir
else
    echo "RAPTOR_SHROUDLY_APP_BUNDLE_MISSING: neither $STAGED_APP_TAR nor a valid $STAGED_APP found" >&2
    exit 1
fi

# --- Install application payload ---------------------------------------------
install -d /opt/raptor-shroudly

case "$PAYLOAD_MODE" in
    tar)
        tar -xzf "$STAGED_APP_TAR" -C /opt/raptor-shroudly
        ;;
    dir)
        cp -a "$STAGED_APP/." /opt/raptor-shroudly/
        ;;
esac

# Hard guarantee the Electron payload is present and non-empty
if [[ ! -s /opt/raptor-shroudly/resources/app.asar ]]; then
    echo "RAPTOR_SHROUDLY_INSTALL_MISSING:/opt/raptor-shroudly/resources/app.asar (payload mode=$PAYLOAD_MODE)" >&2
    ls -la /opt/raptor-shroudly/ 2>/dev/null || true
    ls -la /opt/raptor-shroudly/resources/ 2>/dev/null || true
    exit 1
fi

# --- Launcher, icons, license, policy ----------------------------------------
install -Dm0755 "$STAGED_BIN" /usr/bin/raptor-shroudly
install -Dm0644 "$STAGED_ICON" /usr/share/pixmaps/shroudly.png
install -Dm0644 "$STAGED_ICON" /usr/share/icons/hicolor/256x256/apps/raptor-shroudly.png
install -Dm0644 "$STAGED_LICENSE" /usr/share/licenses/raptor-shroudly/LICENSE
install -Dm0644 "$STAGED_POLICY" /usr/share/polkit-1/actions/me.codeshare.shroudly.policy

# Optional NOTICE with explicit upstream credit (created in CI)
if [[ -s "$STAGED_NOTICE" ]]; then
    install -Dm0644 "$STAGED_NOTICE" /usr/share/doc/raptor-shroudly/NOTICE
fi

# --- Desktop entry (Raptor branding + native categories) ---------------------
install -d /usr/share/applications
cat > /usr/share/applications/raptor-shroudly.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Shroudly
GenericName=Network privacy & DPI bypass
Comment=Raptor OS edition of Shroudly — open blocked sites and apps. Built on the original Shroudly engine with Raptor branding and integration.
Exec=/usr/bin/raptor-shroudly %U
Icon=raptor-shroudly
Terminal=false
Categories=X-RaptorOS;Network;Utility;Security;
Keywords=shroudly;raptor;privacy;network;proxy;DNS;DPI;censorship;school;wifi;
StartupNotify=true
StartupWMClass=shroudly
X-Raptor-OS-Component=true
DESKTOP


command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

# --- Final integrity checks --------------------------------------------------
for required in \
    /usr/bin/raptor-shroudly \
    /opt/raptor-shroudly/resources/app.asar \
    /usr/share/pixmaps/shroudly.png \
    /usr/share/licenses/raptor-shroudly/LICENSE \
    /usr/share/polkit-1/actions/me.codeshare.shroudly.policy \
    /usr/share/applications/raptor-shroudly.desktop; do
    [[ -s "$required" ]] || {
        echo "RAPTOR_SHROUDLY_INSTALL_MISSING:$required" >&2
        exit 1
    }
done

# Size sanity (app.asar should be many megabytes; catch empty/truncated copies)
ASAR_SIZE=$(stat -c%s /opt/raptor-shroudly/resources/app.asar 2>/dev/null || echo 0)
if [[ "$ASAR_SIZE" -lt 1000000 ]]; then
    echo "RAPTOR_SHROUDLY_ASAR_TOO_SMALL:$ASAR_SIZE bytes (expected >1 MiB)" >&2
    exit 1
fi

bash -n /usr/bin/raptor-shroudly
echo "RAPTOR_SHROUDLY_READY: upstream Shroudly engine+UI, Raptor branding, launcher, license, policy and desktop integration installed (payload=$PAYLOAD_MODE, asar=${ASAR_SIZE} bytes)."