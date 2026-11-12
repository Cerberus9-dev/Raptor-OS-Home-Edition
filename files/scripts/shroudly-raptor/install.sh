#!/usr/bin/env bash
set -euo pipefail

# Package the upstream Shroudly Electron desktop app without changing its
# interface. The app bundle is built from the pinned upstream submodule in CI.
STAGE_DIR="/tmp/raptor-staging"
if [[ ! -d "$STAGE_DIR/raptor-shroudly-app" && -d "/tmp/files/staging/raptor-shroudly-app" ]]; then
    STAGE_DIR="/tmp/files/staging"
fi

STAGED_BIN="$STAGE_DIR/raptor-shroudly"
STAGED_APP="$STAGE_DIR/raptor-shroudly-app"
STAGED_ICON="$STAGE_DIR/raptor-shroudly-icon.png"
STAGED_LICENSE="$STAGE_DIR/raptor-shroudly-license"
STAGED_POLICY="$STAGE_DIR/raptor-shroudly-policy"

for required in "$STAGED_BIN" "$STAGED_ICON" "$STAGED_LICENSE" "$STAGED_POLICY"; do
    [[ -s "$required" ]] || {
        echo "RAPTOR_SHROUDLY_PAYLOAD_MISSING:$required" >&2
        exit 1
    }
done
[[ -x "$STAGED_BIN" ]] || { echo "RAPTOR_SHROUDLY_LAUNCHER_NOT_EXECUTABLE" >&2; exit 1; }
[[ -d "$STAGED_APP" && -s "$STAGED_APP/resources/app.asar" ]] || {
    echo "RAPTOR_SHROUDLY_APP_BUNDLE_MISSING:$STAGED_APP" >&2
    exit 1
}

install -d /opt/raptor-shroudly
cp -a "$STAGED_APP/." /opt/raptor-shroudly/
install -Dm0755 "$STAGED_BIN" /usr/bin/raptor-shroudly
install -Dm0644 "$STAGED_ICON" /usr/share/pixmaps/shroudly.png
install -Dm0644 "$STAGED_LICENSE" /usr/share/licenses/raptor-shroudly/LICENSE
install -Dm0644 "$STAGED_POLICY" /usr/share/polkit-1/actions/me.codeshare.shroudly.policy

install -d /usr/share/applications
cat > /usr/share/applications/raptor-shroudly.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Shroudly
GenericName=Network privacy and DPI bypass
Comment=Shroudly desktop application, packaged for Raptor OS
Exec=/usr/bin/raptor-shroudly %U
Icon=shroudly
Terminal=false
Categories=Network;Utility;
Keywords=shroudly;privacy;network;proxy;DNS;
StartupNotify=true
DESKTOP

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true

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

bash -n /usr/bin/raptor-shroudly
echo "RAPTOR_SHROUDLY_READY: upstream Shroudly UI, Electron app, engine, launcher, license and policy installed."
