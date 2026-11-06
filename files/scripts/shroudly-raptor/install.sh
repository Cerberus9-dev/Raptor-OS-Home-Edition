#!/usr/bin/env bash
set -euo pipefail

# Install the original, pinned upstream Shroudly Electron application.
# It is staged only in the one-time update image build. No service or
# autostart entry is created; users start Shroudly explicitly from the menu.
STAGE_DIR="/tmp/raptor-staging/shroudly-app"
APP_DIR="/opt/Shroudly"

if [[ ! -f "/tmp/raptor-staging/include-one-time-apps" ]]; then
    rm -rf "$STAGE_DIR"
    echo "SHROUDLY_SKIP: one-time app payload was not requested."
    exit 0
fi

APP_BIN="$STAGE_DIR/shroudly"
CORE_BIN="$STAGE_DIR/resources/app.asar.unpacked/electron/tools/core/linux-x64/shroudly-core"
ADV_BIN="$STAGE_DIR/resources/app.asar.unpacked/electron/tools/core/linux-x64/shroudly-core-adv"
POLICY="$STAGE_DIR/me.codeshare.shroudly.policy"
ICON="$STAGE_DIR/shroudly.png"
LICENSE="$STAGE_DIR/LICENSE"

for required in "$APP_BIN" "$CORE_BIN" "$ADV_BIN" "$POLICY" "$ICON" "$LICENSE"; do
    if [[ ! -s "$required" ]]; then
        echo "SHROUDLY_INSTALL_ERROR: required upstream payload missing: $required" >&2
        exit 1
    fi
done

install -d "$APP_DIR"
cp -a "$STAGE_DIR/." "$APP_DIR/"
chmod 0755 "$APP_DIR/shroudly" "$APP_DIR/resources/app.asar.unpacked/electron/tools/core/linux-x64/shroudly-core" "$APP_DIR/resources/app.asar.unpacked/electron/tools/core/linux-x64/shroudly-core-adv"
ln -sfn "$APP_DIR/shroudly" /usr/bin/shroudly

install -Dm644 "$APP_DIR/me.codeshare.shroudly.policy" /usr/share/polkit-1/actions/me.codeshare.shroudly.policy
install -Dm644 "$APP_DIR/shroudly.png" /usr/share/icons/hicolor/256x256/apps/shroudly.png

cat > /usr/share/applications/shroudly.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Shroudly
GenericName=Connection Privacy
Comment=Local proxy and connection privacy controls
Exec=/usr/bin/shroudly
Icon=shroudly
Terminal=false
Categories=Network;Utility;
Keywords=shroudly;proxy;privacy;connection;
StartupNotify=true
EOF

command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true

for required in /usr/bin/shroudly /usr/share/applications/shroudly.desktop /usr/share/polkit-1/actions/me.codeshare.shroudly.policy /usr/share/icons/hicolor/256x256/apps/shroudly.png "$APP_DIR/resources/app.asar" "$CORE_BIN" "$ADV_BIN"; do
    [[ -s "$required" ]] || { echo "SHROUDLY_INSTALL_ERROR: installed file missing: $required" >&2; exit 1; }
done

echo "SHROUDLY_READY: original upstream desktop app and Linux engines installed."
echo "No background service or autostart entry was enabled."
