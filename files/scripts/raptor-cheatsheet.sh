#!/bin/bash
set -euo pipefail

# Raptor OS Command Cheatsheet — terminal and GUI reference for Bazzite/Fedora Atomic

mkdir -p /usr/bin /usr/share/applications /usr/share/icons/hicolor/scalable/apps

# ── Terminal cheatsheet ──────────────────────────────────────────────────────
cat << 'EOF' > /usr/bin/raptor-cheatsheet
#!/bin/bash
# Raptor OS Command Cheatsheet — terminal version
# Run without args for interactive fzf search, or with a category name.

CHEATSHEET="
# System Updates (rpm-ostree)
rpm-ostree upgrade                  # Check for and apply system updates
rpm-ostree upgrade --check          # Check for updates without applying
rpm-ostree status                   # Show current deployment and available updates
rpm-ostree rollback                 # Rollback to previous deployment
rpm-ostree deploy <index>           # Switch to a specific deployment
rpm-ostree install <pkg>            # Layer a package (requires reboot)
rpm-ostree uninstall <pkg>          # Remove a layered package
rpm-ostree override replace <pkg>   # Override a base package

# Flatpak Management
flatpak install flathub <app>       # Install an app from Flathub
flatpak update                      # Update all Flatpak apps
flatpak update --app <app>          # Update a specific app
flatpak uninstall <app>             # Uninstall a Flatpak app
flatpak list                        # List installed Flatpak apps
flatpak remote-ls --updates         # List apps with available updates
flatpak override --user <app> --env=VAR=value  # Set env var for an app
flatpak permission-show <app>       # Show permissions for an app
flatpak permission-set <app> <perm> yes/no  # Grant/revoke permission

# Podman / Containers
podman run -it --rm <image>         # Run a container interactively
podman ps -a                        # List all containers
podman images                       # List local images
podman pull <image>                 # Pull an image
podman build -t <name> .            # Build an image from Containerfile
podman volume ls                    # List volumes
podman system prune                 # Clean up unused containers/images
systemctl --user enable --now podman.socket  # Enable rootless Podman API

# Development Toolbox
toolbox create                      # Create a new toolbox container
toolbox enter                       # Enter the default toolbox
toolbox enter <name>                # Enter a specific toolbox
toolbox list                        # List toolbox containers
toolbox rm <name>                   # Remove a toolbox

# Systemd (User)
systemctl --user status <unit>      # Check status of a user service
systemctl --user start <unit>       # Start a user service
systemctl --user enable <unit>      # Enable a user service at login
systemctl --user logs <unit>        # Show logs for a user service
systemctl --user daemon-reload      # Reload user systemd config

# Raptor OS Specific
raptor-cortex                       # Open Raptor Cortex (performance/memory)
raptor-wallpaper                    # Open Raptor Wallpaper picker
raptor-update                       # Open Raptor Update Manager
raptor-wine --help                  # Raptor Wine launcher help
/usr/lib/raptor/cortex-helper set-mode performance
/usr/lib/raptor/cortex-helper trim-background
/usr/lib/raptor/cortex-helper restore-background

# Troubleshooting
coredumpctl list                    # List recent crashes
coredumpctl info <pid>              # Show crash details
journalctl -b -1                    # Show logs from previous boot
journalctl -u <unit> -f             # Follow logs for a unit
dmesg -T                            # Show kernel logs with timestamps
rpm-ostree status --json | jq       # Pretty-print deployment status
flatpak repair                      # Repair Flatpak installation
ostree admin cleanup                # Clean up old deployments

# File System (Atomic)
ls /var                             # Persistent system data (survives updates)
ls /etc                             # Configuration (overlaid, survives updates)
ls /usr                             # Read-only OS image (updated via rpm-ostree)
ls ~/.local                         # User data
ostree admin config-diff            # Show config changes from defaults
"

if [[ $# -eq 0 ]]; then
    if command -v fzf &>/dev/null; then
        echo "$CHEATSHEET" | grep -v '^#' | grep -v '^$' | fzf --prompt='Command > ' --preview='echo {}'
    else
        echo "$CHEATSHEET"
    fi
else
    echo "$CHEATSHEET" | grep -i "$1" | grep -v '^#'
fi
EOF
chmod +x /usr/bin/raptor-cheatsheet

# ── GUI cheatsheet ───────────────────────────────────────────────────────────
cat << 'PYEOF' > /usr/bin/raptor-cheatsheet-gui
#!/usr/bin/env python3
"""Raptor OS Command Cheatsheet — GUI version."""

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib

import sys

CATEGORIES = {
    "System Updates (rpm-ostree)": [
        ("rpm-ostree upgrade", "Check for and apply system updates"),
        ("rpm-ostree upgrade --check", "Check for updates without applying"),
        ("rpm-ostree status", "Show current deployment and available updates"),
        ("rpm-ostree rollback", "Rollback to previous deployment"),
        ("rpm-ostree deploy <index>", "Switch to a specific deployment"),
        ("rpm-ostree install <pkg>", "Layer a package (requires reboot)"),
        ("rpm-ostree uninstall <pkg>", "Remove a layered package"),
        ("rpm-ostree override replace <pkg>", "Override a base package with a different version"),
    ],
    "Flatpak Management": [
        ("flatpak install flathub <app>", "Install an app from Flathub"),
        ("flatpak update", "Update all Flatpak apps"),
        ("flatpak update --app <app>", "Update a specific app"),
        ("flatpak uninstall <app>", "Uninstall a Flatpak app"),
        ("flatpak list", "List installed Flatpak apps"),
        ("flatpak remote-ls --updates", "List apps with available updates"),
        ("flatpak override --user <app> --env=VAR=value", "Set env var for an app"),
        ("flatpak permission-show <app>", "Show permissions for an app"),
        ("flatpak permission-set <app> <perm> yes/no", "Grant/revoke permission"),
    ],
    "Podman / Containers": [
        ("podman run -it --rm <image>", "Run a container interactively"),
        ("podman ps -a", "List all containers"),
        ("podman images", "List local images"),
        ("podman pull <image>", "Pull an image"),
        ("podman build -t <name> .", "Build an image from Containerfile"),
        ("podman volume ls", "List volumes"),
        ("podman system prune", "Clean up unused containers/images"),
        ("systemctl --user enable --now podman.socket", "Enable rootless Podman API"),
    ],
    "Development Toolbox": [
        ("toolbox create", "Create a new toolbox container"),
        ("toolbox enter", "Enter the default toolbox"),
        ("toolbox enter <name>", "Enter a specific toolbox"),
        ("toolbox list", "List toolbox containers"),
        ("toolbox rm <name>", "Remove a toolbox"),
    ],
    "Systemd (User)": [
        ("systemctl --user status <unit>", "Check status of a user service"),
        ("systemctl --user start <unit>", "Start a user service"),
        ("systemctl --user enable <unit>", "Enable a user service at login"),
        ("systemctl --user logs <unit>", "Show logs for a user service"),
        ("systemctl --user daemon-reload", "Reload user systemd config"),
    ],
    "Raptor OS Specific": [
        ("raptor-cortex", "Open Raptor Cortex (performance/memory management)"),
        ("raptor-wallpaper", "Open Raptor Wallpaper picker"),
        ("raptor-update", "Open Raptor Update Manager"),
        ("raptor-wine --help", "Raptor Wine launcher help"),
        ("/usr/lib/raptor/cortex-helper set-mode performance", "Set performance mode"),
        ("/usr/lib/raptor/cortex-helper trim-background", "Trim background services for gaming"),
        ("/usr/lib/raptor/cortex-helper restore-background", "Restore background services"),
    ],
    "Troubleshooting": [
        ("coredumpctl list", "List recent crashes"),
        ("coredumpctl info <pid>", "Show crash details"),
        ("journalctl -b -1", "Show logs from previous boot"),
        ("journalctl -u <unit> -f", "Follow logs for a unit"),
        ("dmesg -T", "Show kernel logs with timestamps"),
        ("rpm-ostree status --json | jq", "Pretty-print deployment status"),
        ("flatpak repair", "Repair Flatpak installation"),
        ("ostree admin cleanup", "Clean up old deployments"),
    ],
    "File System (Atomic)": [
        ("ls /var", "Persistent system data (survives updates)"),
        ("ls /etc", "Configuration (overlaid, survives updates)"),
        ("ls /usr", "Read-only OS image (updated via rpm-ostree)"),
        ("ls ~/.local", "User data"),
        ("ostree admin config-diff", "Show config changes from defaults"),
    ],
}

class CheatsheetWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.set_title("Raptor OS Command Cheatsheet")
        self.set_default_size(700, 600)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)

        hb = Adw.HeaderBar()
        root.append(hb)

        self.toast_overlay = Adw.ToastOverlay()
        self.toast_overlay.set_vexpand(True)
        root.append(self.toast_overlay)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.toast_overlay.set_child(scroll)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        content.set_margin_top(20)
        content.set_margin_bottom(20)
        content.set_margin_start(20)
        content.set_margin_end(20)
        scroll.set_child(content)

        title = Gtk.Label(label="<b>Raptor OS Command Cheatsheet</b>", use_markup=True)
        title.add_css_class("title-1")
        title.set_halign(Gtk.Align.START)
        content.append(title)

        subtitle = Gtk.Label(
            label="Quick reference for Bazzite/Fedora Atomic Silverblue commands.\nClick any command to copy it to clipboard.",
            xalign=0, wrap=True
        )
        subtitle.add_css_class("dim-label")
        content.append(subtitle)

        for cat_name, commands in CATEGORIES.items():
            group = Adw.PreferencesGroup(title=cat_name)
            content.append(group)

            for cmd, desc in commands:
                row = Adw.ActionRow(title=cmd, subtitle=desc)
                row.add_css_class("monospace")
                row.set_activatable(True)
                copy_btn = Gtk.Button(icon_name="edit-copy-symbolic")
                copy_btn.add_css_class("flat")
                copy_btn.set_valign(Gtk.Align.CENTER)
                copy_btn.connect("clicked", lambda *_, c=cmd: self._copy(c))
                row.add_suffix(copy_btn)
                row.connect("activated", lambda *_, c=cmd: self._copy(c))
                group.add(row)

    def _copy(self, text):
        clip = self.get_display().get_clipboard()
        clip.set_text(text)
        toast = Adw.Toast.new(f"Copied: {text}")
        toast.set_timeout(2)
        self.toast_overlay.add_toast(toast)


class CheatsheetApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.cerberus9dev.RaptorCheatsheet")

    def do_activate(self):
        win = CheatsheetWindow(self)
        win.present()


def main():
    app = CheatsheetApp()
    return app.run(sys.argv)


if __name__ == "__main__":
    import sys
    sys.exit(main())
PYEOF
chmod +x /usr/bin/raptor-cheatsheet-gui

# ── .desktop entries ─────────────────────────────────────────────────────────
cat << 'EOF' > /usr/share/applications/raptor-cheatsheet.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=Raptor Cheatsheet
GenericName=Command Reference
Comment=Quick reference for Bazzite/Fedora Atomic commands
Exec=/usr/bin/raptor-cheatsheet-gui
Icon=raptor-cheatsheet
Terminal=false
Categories=X-RaptorOS;Utility;Development;
Keywords=cheatsheet;commands;reference;terminal;bazzite;atomic;
StartupNotify=true
X-KDE-SubstituteUID=false
EOF

cat << 'EOF' > /usr/share/applications/raptor-cheatsheet-terminal.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=Raptor Cheatsheet (Terminal)
GenericName=Command Reference
Comment=Terminal-based command reference for Bazzite/Fedora Atomic
Exec=konsole -e /usr/bin/raptor-cheatsheet
Icon=raptor-cheatsheet
Terminal=true
Categories=X-RaptorOS;Utility;Development;
Keywords=cheatsheet;commands;reference;terminal;bazzite;atomic;
StartupNotify=true
X-KDE-SubstituteUID=false
EOF

# ── Icon ──────────────────────────────────────────────────────────────────────
cat << 'SVGEOF' > /usr/share/icons/hicolor/scalable/apps/raptor-cheatsheet.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#4c1d95"/>
      <stop offset="100%" stop-color="#2e1065"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="url(#bg)"/>
  <circle cx="32" cy="32" r="24" fill="none" stroke="#a78bfa" stroke-width="1.5"
          stroke-dasharray="12 4" stroke-linecap="round"/>
  <text x="32" y="36" text-anchor="middle" fill="#c4b5fd" font-size="28" font-weight="bold">📋</text>
  <line x1="32" y1="10" x2="32" y2="18" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="32" y1="46" x2="32" y2="54" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="10" y1="32" x2="18" y2="32" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="46" y1="32" x2="54" y2="32" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
</svg>
SVGEOF

gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── Self-check ────────────────────────────────────────────────────────────────
RAPTOR_EXPECTED_PAYLOAD="
/usr/bin/raptor-cheatsheet
/usr/bin/raptor-cheatsheet-gui
/usr/share/applications/raptor-cheatsheet.desktop
/usr/share/applications/raptor-cheatsheet-terminal.desktop
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "RAPTOR_CHEATSHEET_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
echo "RAPTOR_CHEATSHEET_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
echo "Raptor Cheatsheet installed successfully."
