#!/bin/bash
set -e

# =============================================================================
# Raptor OS — Update Manager
# GTK4/Adwaita GUI: check for updates, show changelog, update + reboot
# =============================================================================

# ── Polkit policy ─────────────────────────────────────────────────────────────
mkdir -p /usr/share/polkit-1/actions
cat << 'EOF' > /usr/share/polkit-1/actions/io.github.cerberus9dev.raptorupdate.policy
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
  "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>

  <action id="io.github.cerberus9dev.raptorupdate.update">
    <description>Install Raptor OS system update</description>
    <message>Authentication required to install a system update</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/lib/raptor/update-helper</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>

  <action id="io.github.cerberus9dev.raptorupdate.check">
    <description>Check for Raptor OS system updates</description>
    <message>Authentication required to check for system updates</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/lib/raptor/check-helper</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>

  <action id="io.github.cerberus9dev.raptorupdate.flatpak">
    <description>Update Flatpak applications</description>
    <message>Authentication required to update Flatpak applications</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/lib/raptor/flatpak-update-helper</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>

  <action id="io.github.cerberus9dev.raptorupdate.reboot">
    <description>Reboot after Raptor OS system update</description>
    <message>Authentication required to reboot</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/lib/raptor/reboot-helper</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>

</policyconfig>
EOF

# ── Privileged helpers ────────────────────────────────────────────────────────
mkdir -p /usr/lib/raptor

cat << 'EOF' > /usr/lib/raptor/update-helper
#!/bin/bash
# Raptor OS — rpm-ostree update helper with retry and stuck-download recovery.
# Called by the Update Manager GUI via pkexec/sudo.
# All output goes to stdout for the GUI to stream.

MAX_ATTEMPTS=3
LAYER_TIMEOUT=900  # 15 min per attempt — generous for a ~1 GB layer on slow links

check_network() {
    # Quick probe — Raptor OS images live on ghcr.io (Bazzite OCI registry).
    curl -sf --connect-timeout 5 https://ghcr.io/ >/dev/null 2>&1
}

purge_layer_cache() {
    # A big OCI layer can land on disk truncated when the network drops mid-
    # import; rpm-ostree then fails every retry with "Processing tar: ...
    # unexpected end of file" because the cached blob is corrupt and gets
    # reused blind. Purge the fetched-layer + unpacked-content caches between
    # attempts so the next try starts from a clean download.
    rm -rf /var/cache/rpm-ostree-layers /var/cache/rpm-ostree-contents 2>/dev/null || true
}

for attempt in $(seq 1 $MAX_ATTEMPTS); do
    echo "── Attempt ${attempt}/${MAX_ATTEMPTS} ──"

    if ! check_network; then
        echo "Network unreachable — waiting 15 s…"
        sleep 15
        continue
    fi

    # Clear any stale transaction lock left by a previous killed attempt so
    # rpm-ostree doesn't refuse to start ("Another transaction is in progress").
    rm -f /run/lock/rpm-ostree.lock 2>/dev/null || true

    if timeout "${LAYER_TIMEOUT}" rpm-ostree update 2>&1; then
        echo "✓ System update applied — reboot to finish."
        exit 0
    fi

    rc=$?
    if [ "$rc" -eq 124 ]; then
        echo "Timed out after ${LAYER_TIMEOUT} s — clearing stuck state…"
    else
        echo "Failed (exit ${rc}) — clearing corrupt layer cache…"
    fi

    rm -f /run/lock/rpm-ostree.lock 2>/dev/null || true
    purge_layer_cache
    sleep $((attempt * 15))  # 15 s, then 30 s back-off
done

echo "Update failed after ${MAX_ATTEMPTS} attempts. Check your connection."
exit 1
EOF
chmod +x /usr/lib/raptor/update-helper

cat << 'EOF' > /usr/lib/raptor/check-helper
#!/bin/bash
# Refresh rpm-ostree's remote metadata and cache the result *in the current
# deployment's cached-update field*, which `rpm-ostree status --json` then
# reports. Without this step the field stays empty (or stale) and the GUI
# answers "no updates" even when a new base image push exists.
#
# Every attempt is time-bounded so the GUI's update check can NEVER hang
# forever on a stalled network — the worst case is a bounded run of timed-out
# attempts with a clear message (which the GUI streams live into its console).
#
# How `rpm-ostree upgrade --check` reports a *successful* check varies between
# builds and platforms: some signal a clean "nothing new" with exit 77 (KDE
# Discover's backend), others with exit 0 (container-native and rpm-md builds,
# see coreos/rpm-ostree #4891). A bare numeric code is therefore never trusted
# on its own — a printed verdict ("No updates available." or "AvailableUpdate:")
# is ground truth, and only genuinely failed or timed-out attempts are retried.
#
# Even that verdict is NOT enough on container-native images (Bazzite /
# BlueBuild): rpm-ostree can print "No updates available." while a new image
# was just pushed (coreos/rpm-ostree #1579, #4891, #4711). When the check
# completes without announcing an update we therefore cross-verify the *booted
# image digest* against the digest the remote tag resolves to right now — the
# same ground truth ublue-update uses. A mismatch means a new image exists.
MAX_ATTEMPTS=3
ATTEMPT_TIMEOUT=150  # seconds per metadata pull

if curl -sf --connect-timeout 5 https://ghcr.io/ >/dev/null 2>&1; then
    echo "Connectivity to ghcr.io OK."
else
    echo "WARNING: no reachable connectivity to ghcr.io yet — refresh may fail."
fi

# Prints "AvailableUpdate:" (and exits 0) when the registry tag now points at
# a digest different from the one the system is booted on. Silent no-op (exit
# 0) when the machine is not container-native, when a prerequisite is missing,
# or when the comparison cannot be made — the rpm-ostree verdict stands then.
registry_cross_check() {
    command -v skopeo >/dev/null 2>&1 || { echo "NOTE: registry digest cross-check skipped (skopeo not installed)."; return 0; }
    command -v jq     >/dev/null 2>&1 || { echo "NOTE: registry digest cross-check skipped (jq not installed)."; return 0; }

    local json origin ref local_digest host path tag aw remote_digest tmp

    json="$(timeout 60 rpm-ostree status --json 2>/dev/null)" || { echo "Registry cross-check: status --json failed — skipped."; return 0; }
    [ -n "$json" ] || { echo "Registry cross-check: empty status — skipped."; return 0; }

    origin="$(printf '%s' "$json" | jq -r '.deployments[0].origin // empty')"
    [ -n "$origin" ] || { echo "Registry cross-check: no deployment origin — skipped."; return 0; }

    # Classic (non-container) refs like "fedora:fedora/42/x86_64/kinoite" are
    # answered reliably by rpm-ostree itself — nothing to cross-check.
    case "$origin" in
        ostree-image-signed:docker://*|ostree-unverified-image:docker://*)
            ref="${origin#*docker://}" ;;
        ostree-image-signed:registry:*|ostree-unverified-image:registry:*|ostree-unverified-registry:*)
            ref="${origin#*registry:}" ;;
        ostree-image-signed:*|ostree-unverified-image:*)
            ref="${origin#*:}" ;;
        *) return 0 ;;
    esac
    ref="${ref%@sha256:*}"  # drop a digest pin; compare against the moving tag

    local_digest="$(printf '%s' "$json" | jq -r \
        '.deployments[0]["container-image-reference-digest"]
         // .deployments[0]["base-commit-meta"]["ostree.manifest-digest"]
         // empty')"
    [ -n "$local_digest" ] || { echo "Registry cross-check: no local image digest — skipped."; return 0; }

    host="${ref%%/*}"
    path="${ref#*/}"
    if [[ "$path" == *":"* ]]; then
        tag="${path##*:}"
        path="${path%:*}"
    else
        tag="latest"
    fi

    case "$(uname -m)" in
        x86_64)  aw="amd64" ;;
        aarch64) aw="arm64" ;;
        armv7hl) aw="arm" ;;
        *)       aw="$(uname -m)" ;;
    esac

    tmp="$(mktemp)"
    remote_digest=""
    # Registry pull works on a raw manifest-list: pick the entry for OUR arch
    # (filtering out cosign attestation entries via mediaType), so the digest
    # is comparable with the per-arch digest rpm-ostree recorded locally.
    if timeout 45 skopeo inspect --raw "docker://${host}/${path}:${tag}" >"$tmp" 2>/dev/null; then
        if jq -e '.manifests' "$tmp" >/dev/null 2>&1; then
            remote_digest="$(jq -r --arg a "$aw" \
                '.manifests[] |
                 select(.platform.os == "linux" and .platform.architecture == $a) |
                 select((.mediaType // "") | test("oci.image.manifest|distribution.manifest")) |
                 .digest // empty' "$tmp" | head -n 1)"
        else
            remote_digest="$(timeout 45 skopeo inspect --format '{{.Digest}}' \
                "docker://${host}/${path}:${tag}" 2>/dev/null)"
        fi
    fi
    rm -f "$tmp"

    if [ -z "$remote_digest" ]; then
        echo "Registry cross-check: could not resolve ${host}/${path}:${tag} — skipped."
        return 0
    fi

    if [ "$remote_digest" != "$local_digest" ]; then
        echo "──────────────────────────────────────────────"
        echo "New image available:"
        echo "  booted ${local_digest}"
        echo "  remote ${remote_digest}"
        echo "AvailableUpdate:"
        echo "  A new Raptor OS image was pushed to ${host}/${path}:${tag}."
        return 0
    fi
    echo "Registry digest matches the booted image — no new image pushed."
    return 0
}

verdict=0  # 1 once *any* check attempt completed cleanly
for try in $(seq 1 "${MAX_ATTEMPTS}"); do
    echo "── Metadata refresh attempt ${try}/${MAX_ATTEMPTS} ──"
    # Clear any stale transaction lock left by a previous killed attempt so
    # rpm-ostree doesn't refuse to start ("Another transaction is in progress").
    rm -f /run/lock/rpm-ostree.lock 2>/dev/null || true

    # Stream the check output live to the GUI (tee) while keeping a copy for
    # the verdict check; PIPESTATUS[0] is timeout/rpm-ostree's real exit code.
    out="$(mktemp)"
    timeout "${ATTEMPT_TIMEOUT}" rpm-ostree upgrade --check 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}

    # An explicit update announcement is unambiguous — report it immediately.
    if grep -qiE "AvailableUpdate|Available update" "$out"; then
        rm -f "$out"
        exit 0
    fi

    # "No updates available." means the check *ran* — but on container-native
    # images this verdict cannot be trusted (see header), so finish cleanly and
    # let the registry cross-check confirm it. NotFound-free + rc 0/77 counts
    # the same way (bare codes alone are never treated as "update present").
    if grep -qiE "no updates? available|no upgrade available" "$out"; then
        rm -f "$out"
        verdict=1
        break
    fi
    rm -f "$out"

    if [ "$rc" -eq 0 ] || [ "$rc" -eq 77 ]; then
        verdict=1
        break
    fi

    if [ "$rc" -eq 124 ]; then
        echo "Metadata refresh timed out after ${ATTEMPT_TIMEOUT} s — retrying…"
    else
        echo "Metadata refresh did not complete (exit ${rc}) — retrying…"
    fi
    sleep 5
done

if [ "$verdict" -eq 0 ]; then
    echo "Could not refresh remote metadata after ${MAX_ATTEMPTS} attempts."
    echo "Check your connection, then try again."
    exit 1
fi

# Check completed without announcing an update — confirm against the registry
# so a fresh image push is never missed on container-native systems.
registry_cross_check
exit 0
EOF
chmod +x /usr/lib/raptor/check-helper

cat << 'EOF' > /usr/lib/raptor/flatpak-update-helper
#!/bin/bash
# Update both system-wide and user Flatpaks in one privileged pass.
# System Flatpaks: installed by recipe.yml, need root to update.
# User Flatpaks: installed by firstboot picker, technically user-owned
# but handled here for a unified log stream in the GUI.
exec flatpak update --noninteractive --assumeyes 2>&1
EOF
chmod +x /usr/lib/raptor/flatpak-update-helper

cat << 'EOF' > /usr/lib/raptor/reboot-helper
#!/bin/bash
exec systemctl reboot
EOF
chmod +x /usr/lib/raptor/reboot-helper

# ── Sudoers fallback ──────────────────────────────────────────────────────────
mkdir -p /etc/sudoers.d
cat << 'EOF' > /etc/sudoers.d/raptor-update
ALL ALL=(root) NOPASSWD: /usr/lib/raptor/update-helper
ALL ALL=(root) NOPASSWD: /usr/lib/raptor/check-helper
ALL ALL=(root) NOPASSWD: /usr/lib/raptor/flatpak-update-helper
ALL ALL=(root) NOPASSWD: /usr/lib/raptor/reboot-helper
EOF
chmod 440 /etc/sudoers.d/raptor-update
visudo -cf /etc/sudoers.d/raptor-update || true

# ── Background update check ───────────────────────────────────────────────────
# Keep rpm-ostree's cached-update state warm. With AutomaticUpdatePolicy=check
# the rpm-ostreed-automatic timer periodically refreshes the remote metadata
# and records whether a newer deployment exists, so `rpm-ostree status --json`
# gives correct answers even between GUI refreshes. (policy=check only *checks*;
# it never stages or downloads the update — the GUI still drives the real
# update + reboot through update-helper.)
mkdir -p /etc/rpm-ostreed.conf.d
cat << 'EOF' > /etc/rpm-ostreed.conf.d/raptor-auto-check.conf
[Daemon]
AutomaticUpdatePolicy=check
EOF
systemctl enable rpm-ostreed-automatic.timer 2>/dev/null || true

# ── Python GUI ────────────────────────────────────────────────────────────────
cat << 'PYEOF' > /usr/bin/raptor-update
#!/usr/bin/env python3
"""Raptor OS Update Manager"""

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib

import subprocess
import threading
import ssl
import urllib.request
import sys
import re
import select
import os
import time

CHANGELOG_URL         = "https://raw.githubusercontent.com/Cerberus9-dev/Raptor-OS-Home-Edition/refs/heads/main/changelog.md"
UPDATE_HELPER         = "/usr/lib/raptor/update-helper"
CHECK_HELPER          = "/usr/lib/raptor/check-helper"
CHECK_ACTION          = "io.github.cerberus9dev.raptorupdate.check"
FLATPAK_UPDATE_HELPER = "/usr/lib/raptor/flatpak-update-helper"
REBOOT_HELPER         = "/usr/lib/raptor/reboot-helper"
# Wall-clock budget for the whole privileged refresh. check-helper already
# bounds itself to 3 × 150 s attempts + back-off, so this always outlives it —
# the outer bound is a safety net so a stuck network can never hang the GUI
# forever, and the helper output is streamed live meanwhile.
CHECK_TIMEOUT         = 500

# Comprehensive ANSI/VT100 escape sequence stripper:
#   CSI  ESC [ <params> <letter>
#   OSC  ESC ] ... BEL  or  ESC ] ... ESC \
#   ESC + single printable char (ESC M, ESC c, …)
#   bare carriage returns
ANSI_ESCAPE = re.compile(
    r"\x1b(?:"
    r"\[[0-9;]*[A-Za-z]"
    r"|\][^\x07\x1b]*(?:\x07|\x1b\\)"
    r"|[@-Z\\-_]"
    r")|\r",
    re.UNICODE,
)


# ── Helpers ───────────────────────────────────────────────────────────────────

def fetch_changelog():
    """Fetch the remote changelog over verified TLS. No insecure fallback."""
    try:
        ctx = ssl.create_default_context()
        req = urllib.request.Request(
            CHANGELOG_URL,
            headers={"User-Agent": "RaptorOS-UpdateManager/3"},
        )
        with urllib.request.urlopen(req, context=ctx, timeout=12) as r:
            raw = r.read().decode("utf-8")
            if raw.strip():
                return raw
    except Exception:
        pass
    return (
        "Could not load changelog.\n\n"
        "Check your internet connection or visit:\n"
        "https://github.com/Cerberus9-dev/Raptor-OS/blob/main/CHANGELOG.md"
    )


def _local_update_signal():
    """Read only local state (no network) for a pending update.

    Returns (has_update: bool, message: str) or (False, "") when nothing
    local is conclusive. Looks for a cached-update flag and for a staged
    deployment that has not been booted — both are visible without touching
    the network, which matters when the refresh itself just failed."""
    try:
        import json
        result = subprocess.run(
            ["rpm-ostree", "status", "--json"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            return False, ""
        status = json.loads(result.stdout)
        deployments = status.get("deployments", [])
        # cached-update is a bool on older rpm-ostree and a dict on newer.
        for deployment in deployments:
            if deployment.get("cached-update"):
                return True, "A system update is available."
        # A staged-but-not-booted deployment: the newest deployment (index 0)
        # is not the one currently booted, so a newer base image is already
        # on disk — only a reboot is missing.
        if deployments and not deployments[0].get("booted"):
            return True, "System update downloaded — reboot to apply it."
    except Exception:
        pass
    return False, ""


def check_for_updates(emit=None):
    """Check rpm-ostree for a pending deployment upgrade.

    The `cached-update` field in `rpm-ostree status --json` only becomes
    populated after a check has actually run (via `rpm-ostree upgrade --check`
    or the rpm-ostreed-automatic timer). Reading it on its own never triggers
    that, so the resolver first runs the privileged check-helper to refresh
    remote metadata + cache the result, then inspects the check output and
    status --json and combines five independent signals:

      1. an explicit "AvailableUpdate:" line in the check output
      2. a populated `cached-update` field (bool on old rpm-ostree, dict on new)
      3. a *staged* deployment that has not been booted yet — the base image
         was already upgraded elsewhere, only a reboot is missing
      4. a registry digest cross-check: on a clean (non-update) check the
         helper compares the booted image's digest against the remote tag's
         digest (coreos/rpm-ostree #4891 — `--check` can wrongly answer
         "no updates" on container-native images) and prints "AvailableUpdate:"
         again when the tag moved, so a fresh image push is never hidden
      5. a failed refresh surfacing as an error instead of a silent
         "up to date" — but only after checking the local signals, so a
         refresh failure can never hide an update that is already on disk

    `emit(line)` is called from this thread for every line of helper output as
    it arrives, so the GUI can stream the refresh progress live instead of
    showing a frozen spinner. The whole helper invocation is bounded: the
    check-helper itself caps at 3 × 150 s attempts, plus CHECK_TIMEOUT here as
    a hard wall-clock ceiling, plus a select() loop that can never hang on a
    stalled pipe.

    This stays correct across traditional and container-native (Bazzite-style)
    base images, either of which can lag the other on one signal alone.
    Note: rpm-ostree `--check` reports a clean run as either exit 0 or exit 77
    depending on the build — both are success codes, and check-helper exits 0
    whenever a verdict ("No updates available." / "AvailableUpdate:") proves
    the check completed, so a "no update" result is never a refresh failure.

    Returns (has_update: bool, message: str)."""
    refresh_out = ""
    refresh_rc = -1
    try:
        helper = run_privileged(CHECK_HELPER, action_id=CHECK_ACTION)
    except RuntimeError as exc:
        return False, f"Could not start update check ({exc})."

    deadline = time.monotonic() + CHECK_TIMEOUT
    try:
        # select() keeps this loop responsive even when the pipe has no data
        # yet; readline() then never blocks past the next line to arrive.
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                helper.kill()
                refresh_rc = "timeout"
                break
            ready, _, _ = select.select([helper.stdout], [], [], remaining)
            if not ready:
                helper.kill()
                refresh_rc = "timeout"
                break
            line = helper.stdout.readline()
            if not line:
                break
            if emit is not None:
                emit(line)
            refresh_out += line
    except (OSError, ValueError):
        pass

    if refresh_rc != "timeout":
        try:
            refresh_rc = helper.wait(timeout=CHECK_TIMEOUT)
        except subprocess.TimeoutExpired:
            helper.kill()
            helper.wait()
            refresh_rc = "timeout"

    # Clean result codes: 0 or 77 both mean "the check ran and we know the
    # answer" (which code a given rpm-ostree build uses varies), and the
    # helper exits 0 on any completed check via the verdict fallback.
    if refresh_rc == "timeout":
        return False, "Update check timed out while refreshing metadata."
    if isinstance(refresh_rc, int) and refresh_rc not in (0, 77):
        # Belt-and-braces: trust a verdict in the output even if the helper
        # surfaced a quirky exit code — a printed "no update" / "update
        # available" means the check reached an answer, not a failure.
        verdict_ok = re.search(
            r"(?mi)^\s*(?:No\s+updates?\s+available|No\s+upgrade\s+available"
            r"|Available\s*Update)\s*:?",
            refresh_out,
        )
        if not verdict_ok:
            # 4) Refresh failed — but do NOT hide an update already known locally.
            local_has, local_msg = _local_update_signal()
            if local_has:
                return True, local_msg
            tail = [l for l in refresh_out.splitlines() if l.strip()]
            detail = tail[-1] if tail else f"exit {refresh_rc}"
            return False, f"Could not refresh update state ({detail})."

    # 1) Explicit announcement in the check output ("AvailableUpdate:").
    if re.search(r"(?mi)^\s*Available\s*Update\s*:", refresh_out):
        return True, "A system update is available."

    # 2) + 3) local signals: cached-update flag / staged-but-not-booted.
    local_has, local_msg = _local_update_signal()
    if local_has:
        return local_has, local_msg
    if local_msg:
        return local_has, local_msg
    try:
        import json
        result = subprocess.run(
            ["rpm-ostree", "status", "--json"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            return False, f"Could not check for updates (exit {result.returncode})."
    except subprocess.TimeoutExpired:
        return False, "Update check timed out."
    except FileNotFoundError:
        return False, "rpm-ostree not found — is this an OSTree system?"
    except Exception as e:
        return False, f"Error: {e}"
    return False, "System is up to date."


def check_flatpak_updates():
    """Check for pending Flatpak updates across all remotes.
    Returns (has_update: bool, count: int, message: str)."""
    try:
        result = subprocess.run(
            ["flatpak", "remote-ls", "--app", "--updates"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return False, 0, "Could not check Flatpak updates."
        lines = [l for l in result.stdout.splitlines() if l.strip()]
        if lines:
            n = len(lines)
            return True, n, f"{n} Flatpak app{'s' if n != 1 else ''} can be updated."
        return False, 0, "Flatpak apps are up to date."
    except FileNotFoundError:
        return False, 0, ""   # flatpak not present — suppress
    except subprocess.TimeoutExpired:
        return False, 0, "Flatpak check timed out."
    except Exception as e:
        return False, 0, f"Error: {e}"


def run_privileged(helper_path, action_id=None):
    # Prefer `sudo -n`: NOPASSWD rules for the helpers are shipped in
    # /etc/sudoers.d/raptor-update, so this is silent and needs no polkit agent.
    # pkexec is only a fallback and is invoked without --action-id — some polkit
    # builds mis-parse it and fail to even spawn the helper with a GIO error
    # ("cannot run program …"), and the GUI would never reach the fallback.
    for launcher in (["sudo", "-n"], ["pkexec"]):
        try:
            cmd = launcher + [helper_path]
            return subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
        except FileNotFoundError:
            continue
    raise RuntimeError("Neither pkexec nor sudo is available.")




class RaptorUpdateApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.cerberus9dev.RaptorUpdate")
        self.connect("activate", self.on_activate)

    def on_activate(self, app):
        self.win = RaptorUpdateWindow(application=app)
        self.win.present()


class RaptorUpdateWindow(Adw.ApplicationWindow):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.set_title("Raptor Update Manager")
        self.set_default_size(700, 640)
        self._update_running    = False
        self._ostree_has_update = False
        self._flatpak_has_update = False
        self._reboot_cancelled  = False
        self._build_ui()
        threading.Thread(target=self._do_check,       daemon=True).start()
        threading.Thread(target=self._load_changelog, daemon=True).start()

    # ── UI ────────────────────────────────────────────────────────────────────

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)
        root.append(Adw.HeaderBar())

        outer_scroll = Gtk.ScrolledWindow()
        outer_scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        outer_scroll.set_vexpand(True)
        root.append(outer_scroll)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        content.set_margin_top(24)
        content.set_margin_bottom(24)
        content.set_margin_start(24)
        content.set_margin_end(24)
        outer_scroll.set_child(content)

        # Banner
        banner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        banner.set_halign(Gtk.Align.CENTER)

        self.banner_icon = Gtk.Image.new_from_icon_name(
            "software-update-available-symbolic")
        self.banner_icon.set_pixel_size(64)
        self.banner_icon.add_css_class("accent")
        banner.append(self.banner_icon)

        title = Gtk.Label(label="<b>Raptor Update Manager</b>")
        title.set_use_markup(True)
        title.add_css_class("title-1")
        banner.append(title)

        self.subtitle = Gtk.Label(label="Checking for updates…")
        self.subtitle.add_css_class("dim-label")
        banner.append(self.subtitle)
        content.append(banner)

        # Status card
        status_group = Adw.PreferencesGroup()
        content.append(status_group)

        # System (rpm-ostree) row
        self.status_row = Adw.ActionRow(title="System (rpm-ostree)", subtitle="Checking…")
        self.status_icon = Gtk.Image.new_from_icon_name("emblem-synchronizing-symbolic")
        self.status_icon.add_css_class("accent")
        self.status_row.add_prefix(self.status_icon)
        self.check_spinner = Gtk.Spinner()
        self.check_spinner.start()
        self.status_row.add_suffix(self.check_spinner)
        status_group.add(self.status_row)

        # Flatpak row
        self.flatpak_row = Adw.ActionRow(title="Flatpak Apps", subtitle="Checking…")
        self.flatpak_icon = Gtk.Image.new_from_icon_name("emblem-synchronizing-symbolic")
        self.flatpak_icon.add_css_class("accent")
        self.flatpak_row.add_prefix(self.flatpak_icon)
        self.flatpak_spinner = Gtk.Spinner()
        self.flatpak_spinner.start()
        self.flatpak_row.add_suffix(self.flatpak_spinner)
        status_group.add(self.flatpak_row)

        # Changelog
        cl_group = Adw.PreferencesGroup(title="Changelog")
        content.append(cl_group)

        cl_scroll = Gtk.ScrolledWindow()
        cl_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        cl_scroll.set_min_content_height(180)
        cl_scroll.set_vexpand(True)
        cl_scroll.add_css_class("card")

        self.cl_view = Gtk.TextView()
        self.cl_view.set_editable(False)
        self.cl_view.set_cursor_visible(False)
        self.cl_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.cl_view.set_margin_top(12)
        self.cl_view.set_margin_bottom(12)
        self.cl_view.set_margin_start(12)
        self.cl_view.set_margin_end(12)
        self.cl_view.add_css_class("monospace")
        self.cl_buffer = self.cl_view.get_buffer()
        self.cl_buffer.set_text("Loading changelog…")
        cl_scroll.set_child(self.cl_view)
        cl_group.add(cl_scroll)

        # Console — visible from the start so the update check shows its
        # live progress instead of looking hung while metadata refreshes.
        self.log_group = Adw.PreferencesGroup(title="Console")
        content.append(self.log_group)

        self._log_scroll = Gtk.ScrolledWindow()
        self._log_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self._log_scroll.set_min_content_height(160)
        self._log_scroll.set_vexpand(True)
        self._log_scroll.add_css_class("card")

        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.log_view.set_margin_top(8)
        self.log_view.set_margin_bottom(8)
        self.log_view.set_margin_start(8)
        self.log_view.set_margin_end(8)
        self.log_view.add_css_class("monospace")
        self.log_buffer = self.log_view.get_buffer()
        self._log_scroll.set_child(self.log_view)
        self.log_group.add(self._log_scroll)

        # Buttons
        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btn_box.set_halign(Gtk.Align.CENTER)
        content.append(btn_box)

        self.check_btn = Gtk.Button(label="Check Again")
        self.check_btn.add_css_class("pill")
        self.check_btn.set_sensitive(False)
        self.check_btn.connect("clicked", self.on_check_clicked)
        btn_box.append(self.check_btn)

        self.update_btn = Gtk.Button(label="Update & Reboot")
        self.update_btn.add_css_class("suggested-action")
        self.update_btn.add_css_class("pill")
        self.update_btn.set_sensitive(False)
        self.update_btn.connect("clicked", self.on_update_clicked)
        btn_box.append(self.update_btn)

        self.cancel_reboot_btn = Gtk.Button(label="Cancel Reboot")
        self.cancel_reboot_btn.add_css_class("pill")
        self.cancel_reboot_btn.set_visible(False)
        self.cancel_reboot_btn.connect("clicked", self.on_cancel_reboot)
        btn_box.append(self.cancel_reboot_btn)

        self.update_spinner = Gtk.Spinner()
        btn_box.append(self.update_spinner)

    # ── Changelog ─────────────────────────────────────────────────────────────

    def _load_changelog(self):
        text = fetch_changelog()
        GLib.idle_add(self._set_changelog, text)

    def _set_changelog(self, text):
        self.cl_buffer.set_text(text)
        self.cl_view.scroll_to_iter(self.cl_buffer.get_start_iter(), 0, False, 0, 0)

    # ── Update check ──────────────────────────────────────────────────────────

    def on_check_clicked(self, btn):
        self.check_btn.set_sensitive(False)
        self.update_btn.set_sensitive(False)
        self.check_spinner.start()
        self.flatpak_spinner.start()
        self._set_row_status(self.status_row, self.status_icon,
                             "Checking…", "emblem-synchronizing-symbolic", "accent")
        self._set_row_status(self.flatpak_row, self.flatpak_icon,
                             "Checking…", "emblem-synchronizing-symbolic", "accent")
        self.subtitle.set_text("Checking for updates…")
        GLib.idle_add(self._clear_console)
        threading.Thread(target=self._do_check, daemon=True).start()

    def _do_check(self):
        def _emit(line):
            GLib.idle_add(self._append_console, line)
        GLib.idle_add(self._append_console, "── Checking for updates ──\n")
        ostree_has, ostree_msg      = check_for_updates(emit=_emit)
        fp_has, _fp_n, fp_msg       = check_flatpak_updates()
        GLib.idle_add(self._on_check_done, ostree_has, ostree_msg, fp_has, fp_msg)

    def _on_check_done(self, ostree_has, ostree_msg, fp_has, fp_msg):
        self._ostree_has_update  = ostree_has
        self._flatpak_has_update = fp_has
        any_update = ostree_has or fp_has

        self.check_spinner.stop()
        self.flatpak_spinner.stop()
        self.check_btn.set_sensitive(True)

        # System row
        if ostree_has:
            self._set_row_status(self.status_row, self.status_icon,
                                 ostree_msg, "software-update-available-symbolic", "accent")
        else:
            self._set_row_status(self.status_row, self.status_icon,
                                 ostree_msg, "emblem-ok-symbolic", "success")

        # Flatpak row
        if fp_msg:
            fp_icon = "software-update-available-symbolic" if fp_has else "emblem-ok-symbolic"
            fp_css  = "accent" if fp_has else "success"
            self._set_row_status(self.flatpak_row, self.flatpak_icon,
                                 fp_msg, fp_icon, fp_css)
        else:
            self.flatpak_row.set_subtitle("Flatpak not available.")

        # Header banner
        if any_update:
            self.subtitle.set_text("Updates are ready to install.")
            self.banner_icon.set_from_icon_name("software-update-available-symbolic")
            self.update_btn.set_label(
                "Update & Reboot" if ostree_has else "Update Flatpaks")
        else:
            self.subtitle.set_text("Everything is up to date.")
            self.banner_icon.set_from_icon_name("emblem-ok-symbolic")

        self.update_btn.set_sensitive(any_update)

    def _set_row_status(self, row, icon, subtitle, icon_name, css):
        row.set_subtitle(subtitle)
        icon.set_from_icon_name(icon_name)
        for c in ("success", "warning", "error", "accent"):
            icon.remove_css_class(c)
        icon.add_css_class(css)

    # Keep old name as alias for any other callers
    def _set_status(self, subtitle, icon_name, css):
        self._set_row_status(self.status_row, self.status_icon, subtitle, icon_name, css)

    # ── Update + reboot ───────────────────────────────────────────────────────

    def on_update_clicked(self, btn):
        if self._update_running:
            return
        needs_reboot = self._ostree_has_update
        heading   = "Update & Reboot?" if needs_reboot else "Update Flatpak Apps?"
        body      = (
            "Raptor OS will update and reboot when complete.\nSave any open work first."
            if needs_reboot else
            "Flatpak apps will be updated. No reboot required."
        )
        btn_label = "Update & Reboot" if needs_reboot else "Update Now"
        # Adw.AlertDialog (libadwaita ≥ 1.5); fall back to deprecated MessageDialog.
        try:
            dialog = Adw.AlertDialog(heading=heading, body=body)
            dialog.add_response("cancel", "Cancel")
            dialog.add_response("go", btn_label)
            dialog.set_response_appearance("go", Adw.ResponseAppearance.SUGGESTED)
            dialog.connect("response", self._on_confirm_response)
            dialog.present(self)
        except AttributeError:
            dialog = Adw.MessageDialog(
                transient_for=self, heading=heading, body=body)
            dialog.add_response("cancel", "Cancel")
            dialog.add_response("go", btn_label)
            dialog.set_response_appearance("go", Adw.ResponseAppearance.SUGGESTED)
            dialog.connect("response", self._on_confirm_response)
            dialog.present()

    def _on_confirm_response(self, dialog, response):
        if response != "go":
            return
        self._update_running   = True
        self._reboot_cancelled = False
        self.update_btn.set_sensitive(False)
        self.check_btn.set_sensitive(False)
        self.update_spinner.start()
        self.log_group.set_visible(True)
        self.log_buffer.set_text("")
        self._set_status(
            "Updating — do not close this window…",
            "emblem-synchronizing-symbolic", "accent")
        self.subtitle.set_text("Installing update…")
        threading.Thread(target=self._run_update, daemon=True).start()

    # Console helpers — always run on the main/GUI thread via idle_add, so
    # they are safe to call from the check/update worker threads directly.
    def _clear_console(self):
        self.log_buffer.set_text("")

    def _append_console(self, text):
        clean = ANSI_ESCAPE.sub("", text)
        if not clean:
            return
        end_iter = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end_iter, clean)
        def _scroll():
            adj = self._log_scroll.get_vadjustment()
            adj.set_value(adj.get_upper() - adj.get_page_size())
            return False
        GLib.idle_add(_scroll)

    def _append_log(self, text):
        end_iter = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end_iter, text)
        def _scroll():
            adj = self._log_scroll.get_vadjustment()
            adj.set_value(adj.get_upper() - adj.get_page_size())
            return False
        GLib.idle_add(_scroll)

    def _run_update(self):
        # ── Step 1: Flatpak (no reboot, run first) ────────────────────────────
        if self._flatpak_has_update:
            GLib.idle_add(self._append_log, "── Updating Flatpak apps ──\n")
            GLib.idle_add(self._set_row_status,
                          self.flatpak_row, self.flatpak_icon,
                          "Updating…", "emblem-synchronizing-symbolic", "accent")
            try:
                fp_proc = run_privileged(FLATPAK_UPDATE_HELPER)
                for line in fp_proc.stdout:
                    clean = ANSI_ESCAPE.sub("", line)
                    if clean:
                        GLib.idle_add(self._append_log, clean)
                fp_proc.stdout.close()
                fp_rc = fp_proc.wait()
            except Exception as e:
                fp_rc = -1
                GLib.idle_add(self._append_log, f"\nFlatpak error: {e}\n")
            if fp_rc == 0:
                GLib.idle_add(self._set_row_status,
                              self.flatpak_row, self.flatpak_icon,
                              "Flatpak apps updated.", "emblem-ok-symbolic", "success")
                GLib.idle_add(self._append_log, "✓ Flatpak update complete.\n\n")
            else:
                GLib.idle_add(self._set_row_status,
                              self.flatpak_row, self.flatpak_icon,
                              f"Update failed (exit {fp_rc}).",
                              "dialog-warning-symbolic", "warning")

        # ── Step 2: rpm-ostree (reboot needed) ───────────────────────────────
        if not self._ostree_has_update:
            GLib.idle_add(self._on_flatpak_only_success)
            return

        GLib.idle_add(self._append_log, "── Applying system update ──\n")
        try:
            proc = run_privileged(UPDATE_HELPER)
        except RuntimeError as e:
            GLib.idle_add(self._append_log, f"\nERROR: {e}\n")
            GLib.idle_add(self._on_update_error, -1)
            return
        try:
            for line in proc.stdout:
                clean = ANSI_ESCAPE.sub("", line)
                if clean:
                    GLib.idle_add(self._append_log, clean)
            proc.stdout.close()
            rc = proc.wait()
        except Exception as e:
            GLib.idle_add(self._append_log, f"\nERROR reading output: {e}\n")
            GLib.idle_add(self._on_update_error, -1)
            return
        if rc == 0:
            GLib.idle_add(self._on_update_success)
        else:
            GLib.idle_add(self._on_update_error, rc)

    def _on_flatpak_only_success(self):
        self._update_running = False
        self.update_spinner.stop()
        self._append_log("\n✓ All Flatpak apps are now up to date.\n")
        self._set_status("Flatpak apps updated. No reboot required.",
                         "emblem-ok-symbolic", "success")
        self.subtitle.set_text("Apps updated successfully.")
        self.check_btn.set_sensitive(True)

    def _on_update_success(self):
        self._update_running = False
        self.update_spinner.stop()
        self._append_log("\n✓ System update complete. Rebooting in 15 seconds…\n")
        self._set_status(
            "Update complete! Rebooting in 15 seconds…",
            "emblem-ok-symbolic", "success")
        self.subtitle.set_text("Update installed successfully.")
        self.cancel_reboot_btn.set_visible(True)
        self._countdown(15)

    def _countdown(self, secs):
        if self._reboot_cancelled:
            return
        if secs <= 0:
            self._do_reboot()
            return
        self._set_status(
            f"Rebooting in {secs} second{'s' if secs != 1 else ''} — "
            "click Cancel Reboot to stop",
            "emblem-ok-symbolic", "success")
        GLib.timeout_add_seconds(1, self._tick_countdown, secs - 1)

    def _tick_countdown(self, secs):
        """One-shot GLib timeout callback that advances the countdown."""
        self._countdown(secs)
        return False  # do not repeat

    def _do_reboot(self):
        # Clear the sycoca cache and deployment hash BEFORE rebooting.
        # The new OSTree deployment activates during the reboot; if the
        # stale cache is still on disk when Plasma starts after the reboot,
        # Kickoff shows blank categories. Wiping it here guarantees the
        # sycoca-rebuild.sh autostart will do a full clean rebuild.
        try:
            import glob, os
            cache_dir = os.path.expanduser('~/.cache')
            for f in glob.glob(os.path.join(cache_dir, 'ksycoca6_*')) + \
                     glob.glob(os.path.join(cache_dir, 'ksycoca5_*')):
                try:
                    os.remove(f)
                except OSError:
                    pass
            # Remove the deployment hash so sycoca-rebuild.sh forces a
            # full --noincremental rebuild on next login regardless.
            deploy_hash = os.path.join(cache_dir, 'raptor-deploy-hash')
            if os.path.exists(deploy_hash):
                os.remove(deploy_hash)
            GLib.idle_add(self._append_log,
                '\nSycoca cache cleared — app launcher will rebuild on next login.\n')
        except Exception as e:
            GLib.idle_add(self._append_log, f'\nWarning: could not clear sycoca cache: {e}\n')

        try:
            proc = run_privileged(REBOOT_HELPER)
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                pass  # system is going down — expected
        except Exception as e:
            GLib.idle_add(self._append_log, f"\nERROR rebooting: {e}\n")
            GLib.idle_add(self._set_status,
                "Could not reboot automatically — please reboot manually.",
                "dialog-warning-symbolic", "warning")

    def on_cancel_reboot(self, btn):
        self._reboot_cancelled = True
        self.cancel_reboot_btn.set_visible(False)
        self._set_status(
            "Reboot cancelled — reboot manually when ready.",
            "emblem-ok-symbolic", "success")
        self.check_btn.set_sensitive(True)

    def _on_update_error(self, code):
        self._update_running = False
        self.update_spinner.stop()
        self.update_btn.set_sensitive(True)
        self.check_btn.set_sensitive(True)
        self._set_status(
            f"Update failed (exit {code}). See log above for details.",
            "dialog-error-symbolic", "error")
        self.subtitle.set_text("Something went wrong.")



if __name__ == "__main__":
    app = RaptorUpdateApp()
    sys.exit(app.run(sys.argv))
PYEOF
chmod +x /usr/bin/raptor-update

# ── Launcher wrapper ──────────────────────────────────────────────────────────
cat << 'EOF' > /usr/bin/raptor-update-launcher
#!/bin/bash
# Do NOT set DBUS_SESSION_BUS_ADDRESS here — the login session already sets it
# correctly. Overriding it with a uid formula breaks portal D-Bus calls.
export ADW_DISABLE_PORTAL=1
exec /usr/bin/raptor-update "$@"
EOF
chmod +x /usr/bin/raptor-update-launcher

# ── Custom icon ───────────────────────────────────────────────────────────────
mkdir -p /usr/share/icons/hicolor/scalable/apps
cat << 'SVGEOF' > /usr/share/icons/hicolor/scalable/apps/raptor-update.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#1a2a1a"/>
      <stop offset="100%" stop-color="#0d150d"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="url(#bg)" stroke="#2ec27e" stroke-width="1.5"/>
  <line x1="32" y1="13" x2="32" y2="40" stroke="#2ec27e" stroke-width="5"
        stroke-linecap="round"/>
  <polyline points="20,30 32,44 44,30" stroke="#2ec27e" stroke-width="5"
            stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  <rect x="18" y="49" width="28" height="4" rx="2" fill="#2ec27e"/>
  <path d="M 14 22 A 20 20 0 0 1 50 22" fill="none" stroke="#1e90ff"
        stroke-width="2" stroke-linecap="round" opacity="0.6"/>
</svg>
SVGEOF

gtk-update-icon-cache -f /usr/share/icons/hicolor/ 2>/dev/null || true

# ── .desktop entry ────────────────────────────────────────────────────────────
mkdir -p /usr/share/applications
cat << 'EOF' > /usr/share/applications/raptor-update.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=Raptor Update Manager
GenericName=System Update Manager
Comment=Check and install Raptor OS system updates
Exec=/usr/bin/raptor-update-launcher
Icon=raptor-update
Terminal=false
Categories=X-RaptorOS;System;
Keywords=update;upgrade;system;raptor;ostree;bazzite;
StartupNotify=true
X-KDE-SubstituteUID=false
EOF

echo "UPDATE_MANAGER_READY"
