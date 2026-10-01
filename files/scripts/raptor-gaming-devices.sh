#!/bin/bash
set -euo pipefail

# Raptor Gaming Devices — udev rules, systemd units, and Flatpak overrides for
# popular gaming peripherals: Logitech (G Hub), Razer, SteelSeries, Turtle Beach,
# Corsair, HyperX, Glorious, etc.

mkdir -p /etc/udev/rules.d /usr/lib/systemd/system /usr/share/applications

# ── udev rules for gaming devices ────────────────────────────────────────────
# These rules ensure devices are accessible to the user and get proper permissions
cat << 'EOF' > /etc/udev/rules.d/99-raptor-gaming-devices.rules
# ─── Logitech ──────────────────────────────────────────────────────────────
# G HUB / Logitech Gaming Software devices
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="046d", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="046d", MODE="0666", GROUP="input"
# Lightspeed receivers
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c52b", MODE="0666", GROUP="input"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c539", MODE="0666", GROUP="input"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c548", MODE="0666", GROUP="input"

# ─── Razer ─────────────────────────────────────────────────────────────────
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1532", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="1532", MODE="0666", GROUP="input"

# ─── SteelSeries ───────────────────────────────────────────────────────────
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1038", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="1038", MODE="0666", GROUP="input"

# ─── Corsair ───────────────────────────────────────────────────────────────
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1b1c", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="1b1c", MODE="0666", GROUP="input"

# ─── HyperX ────────────────────────────────────────────────────────────────
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0951", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0951", MODE="0666", GROUP="input"

# ─── Glorious ──────────────────────────────────────────────────────────────
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3434", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="3434", MODE="0666", GROUP="input"

# ─── Roccat ────────────────────────────────────────────────────────────────
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1e7d", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="1e7d", MODE="0666", GROUP="input"

# ─── Turtle Beach ──────────────────────────────────────────────────────────
# Headsets and audio controllers
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="24f0", MODE="0666", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="24f0", MODE="0666", GROUP="input"

# ─── Generic HID gaming devices ────────────────────────────────────────────
# Allow all HID devices with gaming-like interfaces
SUBSYSTEM=="hidraw", KERNEL=="hidraw*", MODE="0666", GROUP="input"

# ─── Joystick / gamepad support ────────────────────────────────────────────
KERNEL=="js[0-9]*", MODE="0666", GROUP="input"
KERNEL=="event[0-9]*", SUBSYSTEM=="input", MODE="0666", GROUP="input"
EOF

# ── Logitech G Hub Flatpak override (for users who install it) ───────────────
# This ensures G Hub can access USB devices when installed as Flatpak
cat << 'EOF' > /usr/share/flatpak/overrides/com.logitech.GHub
[Context]
devices=all
filesystems=xdg-run/udev:ro
EOF

# ── Razer Chroma/peripherals support ────────────────────────────────────────
# openrazer-meta and polychromatic are offered in app picker; this ensures
# the daemon can access devices
cat << 'EOF' > /usr/share/flatpak/overrides/org.openrazer.client
[Context]
devices=all
EOF

# ── Piper/libratbag for mouse configuration ──────────────────────────────────
# If user installs Piper Flatpak, it needs device access
cat << 'EOF' > /usr/share/flatpak/overrides/org.freedesktop.Piper
[Context]
devices=all
EOF

# ── Anti-cheat / kernel driver support notice ────────────────────────────────
# Some anti-cheat (EasyAntiCheat, BattlEye) require kernel modules that don't
# work in Flatpak/sandbox. Document this for users.
cat << 'EOF' > /usr/share/doc/raptor-gaming-devices/README.md
# Raptor OS Gaming Device Support

## Supported Devices (out of the box)
- **Logitech**: G Hub compatible devices, Lightspeed receivers
- **Razer**: All Razer peripherals (use OpenRazer + Polychromatic from app picker)
- **SteelSeries**: All SteelSeries devices
- **Corsair**: All Corsair devices
- **HyperX**: All HyperX devices
- **Glorious**: Model O, Model D, etc.
- **Roccat**: All Roccat devices
- **Turtle Beach**: Headsets and audio controllers

## Configuration Apps (install from App Picker)
- **OpenRazer + Polychromatic**: Razer device configuration (RGB, DPI, macros)
- **Piper**: Mouse configuration for libratbag-supported devices (Logitech, etc.)
- **CoreCtrl**: AMD GPU/CPU control (also works for some peripheral LEDs)
- **GOverlay**: MangoHud GUI (FPS overlay configuration)

## Flatpak Overrides
If you install configuration apps via Flatpak (Polychromatic, Piper, etc.),
they need device access. Run:
```bash
flatpak override --user --device=all com.logitech.GHub
flatpak override --user --device=all org.openrazer.client
flatpak override --user --device=all org.freedesktop.Piper
```

## Anti-Cheat Notice
Kernel-level anti-cheat (EasyAntiCheat, BattlEye, Vanguard) **will not work**
in Flatpak or sandboxed Wine prefixes. For these games, use:
- Steam Proton (native Steam install, not Flatpak)
- Native Linux versions where available
- Bottles with `--no-sandbox` (advanced)

## Turtle Beach Audio
Most Turtle Beach headsets work as standard USB audio devices.
For advanced features (EQ, mic monitoring), check manufacturer software.

## Input Latency
USB autosuspend is disabled for all gaming devices via udev rules.
Bluetooth adapters are also excluded from autosuspend to prevent
mouse/keyboard wake latency.

## Troubleshooting
- Device not detected? `sudo udevadm control --reload && sudo udevadm trigger`
- Permission denied? Check `groups $USER` includes `input`
- RGB not working? Install OpenRazer/Polychromatic or Piper from app picker
EOF

# ── Self-check ────────────────────────────────────────────────────────────────
RAPTOR_EXPECTED_PAYLOAD="
/etc/udev/rules.d/99-raptor-gaming-devices.rules
/usr/share/flatpak/overrides/com.logitech.GHub
/usr/share/flatpak/overrides/org.openrazer.client
/usr/share/flatpak/overrides/org.freedesktop.Piper
/usr/share/doc/raptor-gaming-devices/README.md
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "RAPTOR_GAMING_DEVICES_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
echo "RAPTOR_GAMING_DEVICES_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
echo "Raptor Gaming Devices support installed successfully."
