#!/bin/bash
set -euo pipefail

# One-time upstream Shroudly integration for the v3.0.0 image only.
# The original Electron desktop application and both Linux engines are built
# from the pinned upstream submodule by CI and staged in files/staging/.
# No recurring service or boot-time installation task is created.

STAGE_DIR="/tmp/raptor-staging"
APP_SRC="${STAGE_DIR}/shroudly-app"
APP_DEST="/opt/Shroudly"

if [[ ! -f "${STAGE_DIR}/.include-one-time-apps" ]]; then
    rm -rf "${APP_SRC}" "${STAGE_DIR}/shroudly.png" \
        "${STAGE_DIR}/shroudly-LICENSE" "${STAGE_DIR}/shroudly-polkit.policy"
    echo "SHROUDLY_SKIP: one-time v3.0.0 payload not enabled."
    exit 0
fi

if [[ ! -x "${APP_SRC}/shroudly" ]]; then
    echo "SHROUDLY_FATAL: original upstream Shroudly app binary is missing." >&2
    exit 1
fi
CORE_DIR="${APP_SRC}/resources/app.asar.unpacked/electron/tools/core/linux-x64"
for binary in shroudly-core shroudly-core-adv; do
    if [[ ! -x "${CORE_DIR}/${binary}" ]]; then
        echo "SHROUDLY_FATAL: required upstream Linux engine is missing: ${binary}" >&2
        exit 1
    fi
done
for artifact in shroudly.png shroudly-LICENSE shroudly-polkit.policy; do
    if [[ ! -s "${STAGE_DIR}/${artifact}" ]]; then
        echo "SHROUDLY_FATAL: required upstream integration artifact is missing: ${artifact}" >&2
        exit 1
    fi
done

install -d -m 0755 "${APP_DEST}"
cp -a "${APP_SRC}/." "${APP_DEST}/"
chmod 0755 "${APP_DEST}/shroudly" "${CORE_DIR}/shroudly-core" "${CORE_DIR}/shroudly-core-adv"

install -Dm0644 "${STAGE_DIR}/shroudly.png" \
    /usr/share/icons/hicolor/256x256/apps/shroudly.png
install -Dm0644 "${STAGE_DIR}/shroudly-LICENSE" \
    /usr/share/licenses/shroudly/UPSTREAM-LICENSE
install -Dm0644 "${STAGE_DIR}/shroudly-polkit.policy" \
    /usr/share/polkit-1/actions/me.codeshare.shroudly.policy

mkdir -p /usr/share/applications
cat << 'EOF' > /usr/share/applications/shroudly.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Shroudly
GenericName=Network Privacy Application
Comment=Upstream Shroudly desktop application
Exec=/opt/Shroudly/shroudly %U
Icon=shroudly
Terminal=false
Categories=Network;Utility;
Keywords=shroudly;network;privacy;proxy;
StartupNotify=true
StartupWMClass=shroudly
EOF

gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true

# Fail the image build rather than ship a desktop entry with missing engines.
test -x /opt/Shroudly/shroudly
test -x /opt/Shroudly/resources/app.asar.unpacked/electron/tools/core/linux-x64/shroudly-core
test -x /opt/Shroudly/resources/app.asar.unpacked/electron/tools/core/linux-x64/shroudly-core-adv
test -s /usr/share/polkit-1/actions/me.codeshare.shroudly.policy
test -s /usr/share/applications/shroudly.desktop
echo "SHROUDLY_READY original upstream UI and Linux engines installed; no boot service added."
