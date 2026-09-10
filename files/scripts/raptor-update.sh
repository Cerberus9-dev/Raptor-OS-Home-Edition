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
# Retries once on timeout / network blip so the GUI check doesn't falsely
# report "up to date" just because a metadata fetch stalled.
for try in 1 2; do
    rm -f /run/lock/rpm-ostree.lock 2>/dev/null || true
    if timeout 180 rpm-ostree upgrade --check 2>&1; then
        exit 0
    fi
    rc=$?
    [ "$rc" -eq 124 ] && echo "Metadata refresh timed out — retrying…" || true
    sleep 5
done
# Final attempt — no timeout so slow connections aren't cut short twice.
rm -f /run/lock/rpm-ostree.lock 2>/dev/null || true
exec rpm-ostree upgrade --check 2>&1
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

CHANGELOG_URL         = "https://raw.githubusercontent.com/Cerberus9-dev/Raptor-OS/refs/heads/main/changelog.md"
UPDATE_HELPER         = "/usr/lib/raptor/update-helper"
CHECK_HELPER          = "/usr/lib/raptor/check-helper"
CHECK_ACTION          = "io.github.cerberus9dev.raptorupdate.check"
FLATPAK_UPDATE_HELPER = "/usr/lib/raptor/flatpak-update-helper"
REBOOT_HELPER         = "/usr/lib/raptor/reboot-helper"

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


def check_for_updates():
    """Check rpm-ostree for a pending deployment upgrade.

    The `cached-update` field in `rpm-ostree status --json` only becomes
    populated after a check has actually run (via `rpm-ostree upgrade --check`
    or the rpm-ostreed-automatic timer). Reading it on its own never triggers
    that, so the resolver first runs the privileged check-helper to refresh
    remote metadata + cache the result, then inspects the check output and
    status --json and combines four independent signals:

      1. an explicit "AvailableUpdate:" line in the check output
      2. a populated `cached-update` field (bool on old rpm-ostree, dict on new)
      3. a *staged* deployment that has not been booted yet — the base image
         was already upgraded elsewhere, only a reboot is missing
      4. a failed refresh surfacing as an error instead of a silent
         "up to date"

    This stays correct across traditional and container-native (Bazzite-style)
    base images, either of which can lag the other on one signal alone.
    Note: rpm-ostree `--check` exits 77 for a clean "nothing new" result —
    that is a success code, not a refresh failure.

    Returns (has_update: bool, message: str)."""
    refresh_out = ""
    refresh_rc = -1
    try:
        proc = run_privileged(CHECK_HELPER, action_id=CHECK_ACTION)
        refresh_out, _ = proc.communicate(timeout=180)
        refresh_rc = proc.returncode
    except subprocess.TimeoutExpired:
        if proc is not None:
            proc.kill()
        refresh_rc = "timeout"
    except Exception:
        refresh_rc = -1

    # Clean result codes: 0 = check ran, 77 = check ran + nothing new.
    if refresh_rc == "timeout":
        return False, "Update check timed out while refreshing metadata."
    if isinstance(refresh_rc, int) and refresh_rc not in (0, 77):
        tail = [l for l in refresh_out.splitlines() if l.strip()]
        detail = tail[-1] if tail else f"exit {refresh_rc}"
        return False, f"Could not refresh update state ({detail})."

    # 1) Explicit announcement in the check output ("AvailableUpdate:").
    if re.search(r"(?mi)^\s*Available\s*Update\s*:", refresh_out):
        return True, "A system update is available."

    try:
        result = subprocess.run(
            ["rpm-ostree", "status", "--json"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            return False, f"Could not check for updates (exit {result.returncode})."
        import json
        status = json.loads(result.stdout)
        deployments = status.get("deployments", [])
        # 2) cached-update is a bool on older rpm-ostree and a dict on newer.
        for deployment in deployments:
            if deployment.get("cached-update"):
                return True, "A system update is available."
        # 3) A staged-but-not-booted deployment: the newest deployment (index 0)
        #    is not the one currently booted, so a newer base image is already
        #    on disk — only a reboot is missing.
        if deployments and not deployments[0].get("booted"):
            return True, "System update downloaded — reboot to apply it."
        return False, "System is up to date."
    except subprocess.TimeoutExpired:
        return False, "Update check timed out."
    except FileNotFoundError:
        return False, "rpm-ostree not found — is this an OSTree system?"
    except Exception as e:
        return False, f"Error: {e}"


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
    for launcher in (["pkexec"], ["sudo"]):
        try:
            cmd = launcher + [helper_path]
            if launcher[0] == "pkexec" and action_id:
                cmd = [launcher[0], "--action-id", action_id, helper_path]
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

        # Update log (hidden until update starts)
        self.log_group = Adw.PreferencesGroup(title="Update Log")
        self.log_group.set_visible(False)
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
        threading.Thread(target=self._do_check, daemon=True).start()

    def _do_check(self):
        ostree_has, ostree_msg      = check_for_updates()
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
