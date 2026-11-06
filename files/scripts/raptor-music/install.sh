#!/bin/bash
set -euo pipefail

# Raptor Music: install the prebuilt desktop binary shipped by CI.
# The binary is built from ../../raptor-music and staged into files/staging/
# by .github/workflows/build.yml, then copied to /tmp/raptor-staging by the
# recipe's files module. Local builds that did not stage a binary are skipped
# with a warning instead of failing the whole image build.

STAGE_DIR="/tmp/raptor-staging"
SRC_BIN="${STAGE_DIR}/raptor-music"

# CI stages this executable only for the one-time integration build. Ordinary
# builds contain no binary and safely skip; no separate marker file is needed.
if [[ ! -x "$SRC_BIN" ]]; then
    echo "RAPTOR_MUSIC_SKIP: no one-time Raptor Music payload in this image build."
    exit 0
fi
BIN_DEST="/usr/bin/raptor-music"

mkdir -p /usr/bin /usr/share/applications /usr/share/icons/hicolor/scalable/apps

install -m 0755 "$SRC_BIN" "$BIN_DEST"

# ── .desktop ──────────────────────────────────────────────────────────────────
cat << 'EOF' > /usr/share/applications/raptor-music.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Raptor Music
GenericName=Music Player
Comment=Native music player for Raptor OS
Exec=/usr/bin/raptor-music
Icon=raptor-music
Terminal=false
Categories=X-RaptorOS;AudioVideo;Audio;Player;Music;
Keywords=music;audio;player;library;raptor;
StartupNotify=true
X-KDE-SubstituteUID=false
EOF

# ── Icon ──────────────────────────────────────────────────────────────────────
cat << 'SVGEOF' > /usr/share/icons/hicolor/scalable/apps/raptor-music.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#7c3aed"/>
      <stop offset="100%" stop-color="#4c1d95"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="url(#bg)"/>
  <path d="M24 44V22l20-5v22" fill="none" stroke="#e9d5ff" stroke-width="3"
        stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="21" cy="44" r="5" fill="#e9d5ff"/>
  <circle cx="41" cy="39" r="5" fill="#e9d5ff"/>
</svg>
SVGEOF

gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── Self-check ────────────────────────────────────────────────────────────────
RAPTOR_EXPECTED_PAYLOAD="
$BIN_DEST
/usr/share/applications/raptor-music.desktop
/usr/share/icons/hicolor/scalable/apps/raptor-music.svg
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "RAPTOR_MUSIC_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
echo "RAPTOR_MUSIC_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
echo "Raptor Music installed successfully."
