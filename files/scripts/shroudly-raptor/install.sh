#!/bin/bash
set -euo pipefail

# Shroudly Raptor: install the prebuilt proxy daemon shipped by CI.
# Source lives in shroudly-raptor/ (Cargo.toml + src/) and is built by
# .github/workflows/build.yml, then staged into files/staging/. The recipe's
# files module copies that directory to /tmp/raptor-staging. Local builds that
# did not stage a binary are skipped with a warning instead of failing.

# One-time payload gate: only a manually dispatched build with the explicit
# include_one_time_apps input may install this application into the image.
if [[ ! -f "/tmp/raptor-staging/.include-one-time-apps" ]]; then
    rm -f "/tmp/raptor-staging/shroudly-raptor"
    echo "SHROUDLY_RAPTOR_SKIP: one-time app integration was not requested; staged binary removed."
    exit 0
fi

STAGE_DIR="/tmp/raptor-staging"
SRC_BIN="${STAGE_DIR}/shroudly-raptor"
BIN_DEST="/usr/bin/shroudly-raptor"

mkdir -p /usr/bin /usr/share/applications /usr/share/icons/hicolor/scalable/apps

if [[ ! -x "$SRC_BIN" ]]; then
    echo "SHROUDLY_RAPTOR_SKIP: no prebuilt binary at ${SRC_BIN}." >&2
    echo "Build it with: (cd shroudly-raptor && cargo build --release --workspace)" >&2
    echo "Then copy target/release/shroudly-raptor to files/staging/shroudly-raptor." >&2
    exit 0
fi

install -m 0755 "$SRC_BIN" "$BIN_DEST"

# ── .desktop ──────────────────────────────────────────────────────────────────
# The current build provides local application monitoring only. It does not
# provide upstream proxy routing or packet processing.
cat << 'EOF' > /usr/share/applications/shroudly-raptor.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Raptor Shroudly
GenericName=Local Application Monitor
Comment=Detects supported running apps; network routing is not enabled
Exec=/usr/bin/shroudly-raptor
Icon=shroudly-raptor
Terminal=true
Categories=X-RaptorOS;Network;Utility;
Keywords=shroudly;raptor;games;applications;monitoring;
StartupNotify=false
X-KDE-SubstituteUID=false
EOF

# ── Icon ──────────────────────────────────────────────────────────────────────
cat << 'SVGEOF' > /usr/share/icons/hicolor/scalable/apps/shroudly-raptor.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#0ea5e9"/>
      <stop offset="100%" stop-color="#0c4a6e"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="url(#bg)"/>
  <path d="M32 12 L48 19 V32 C48 42 41 49 32 53 C23 49 16 42 16 32 V19 Z"
        fill="none" stroke="#e0f2fe" stroke-width="3" stroke-linejoin="round"/>
  <path d="M25 32 L30 37 L40 26" fill="none" stroke="#bae6fd" stroke-width="3"
        stroke-linecap="round" stroke-linejoin="round"/>
</svg>
SVGEOF

gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── Self-check ────────────────────────────────────────────────────────────────
RAPTOR_EXPECTED_PAYLOAD="
$BIN_DEST
/usr/share/applications/shroudly-raptor.desktop
/usr/share/icons/hicolor/scalable/apps/shroudly-raptor.svg
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "SHROUDLY_RAPTOR_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
echo "SHROUDLY_RAPTOR_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
echo "Shroudly Raptor installed successfully."
