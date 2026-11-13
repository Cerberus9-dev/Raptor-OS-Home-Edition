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
STAGED_APP_DIR="$STAGE_DIR/raptor-shroudly-app"
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
elif [[ -d "$STAGED_APP_DIR" && -s "$STAGED_APP_DIR/resources/app.asar" ]]; then
    PAYLOAD_MODE=dir
else
    echo "RAPTOR_SHROUDLY_APP_BUNDLE_MISSING: neither $STAGED_APP_TAR nor a valid $STAGED_APP_DIR found" >&2
    exit 1
fi

# --- Install application payload ---------------------------------------------
install -d /opt/raptor-sh