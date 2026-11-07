#!/usr/bin/env bash
set -euo pipefail

# Install the Raptor-customized Shroudly desktop application built by CI.
STAGED_BIN="/tmp/raptor-staging/raptor-shroudly"
if [[ ! -x "$STAGED_BIN" && -x "/tmp/files/staging/raptor-shroudly" ]]; then
    STAGED_BIN="/tmp/files/staging/raptor-shroudly"
fi

if [[ ! -x "$STAGED_BIN" ]]; then
    echo "RAPTOR_SHROUDLY_SKIP: custom application payload was not staged." >&2
    exit 1
fi

install -Dm0755 "$STAGED_BIN" /usr/bin/raptor-shroudly
install -d /usr/share/applications /usr/share/icons/hicolor/scalable/apps

cat > /usr/share/applications/raptor-shroudly.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=Raptor Shroudly
GenericName=Application Compatibility Monitor
Comment=Raptor OS application detection and compatibility dashboard
Exec=/usr/bin/raptor-shroudly
Icon=raptor-shroudly
Terminal=false
Categories=X-RaptorOS;Utility;System;
Keywords=raptor;shroudly;gaming;compatibility;applications;network;
StartupNotify=true
DESKTOP

cat > /usr/share/icons/hicolor/scalable/apps/raptor-shroudly.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#8bd4f1"/>
      <stop offset="1" stop-color="#17466b"/>
    </linearGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="#0b1420"/>
  <circle cx="32" cy="32" r="24" fill="none" stroke="url(#g)" stroke-width="3"/>
  <path d="M20 24h24v18H20z" rx="3" fill="none" stroke="#d9efff" stroke-width="2.5"/>
  <path d="M25 31h14M25 36h9" stroke="#8bd4f1" stroke-width="2.5" stroke-linecap="round"/>
  <circle cx="44" cy="20" r="5" fill="#8bd4f1"/>
</svg>
SVG

command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications 2>/dev/null || true

for required in /usr/bin/raptor-shroudly /usr/share/applications/raptor-shroudly.desktop /usr/share/icons/hicolor/scalable/apps/raptor-shroudly.svg; do
    [[ -s "$required" ]] || { echo "RAPTOR_SHROUDLY_PAYLOAD_MISSING:$required" >&2; exit 1; }
done

echo "RAPTOR_SHROUDLY_READY: custom Raptor application, launcher, desktop entry and icon installed."
