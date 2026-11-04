#!/bin/bash
set -euo pipefail

# =============================================================================
# Raptor Wallpaper  v2.0
# GTK4/Adwaita wallpaper picker with direct KDE Plasma integration.
#
# v2.0 is a full rewrite of v1.0, which was never wired into recipe.yml and
# never actually shipped. Along the way: gallery grid (Windows Personalization
# style — click a thumbnail, it applies) replacing the old single
# browse-one-file flow; fit mode control (Fill/Fit/Stretch/Center/Tile),
# which v1.0 had no way to set at all; four bundled Raptor-branded wallpapers
# so the gallery isn't empty on a fresh install; icon and .desktop rebuilt to
# match the Cortex/GPU Profiler visual family (v1.0's icon was still on the
# pre-conversion blue palette and the .desktop pointed at a generic system
# icon name instead of the custom one); and a Dolphin right-click
# "Set as Raptor Wallpaper" context menu entry — right-click any image file
# and apply it directly, the way Windows Explorer lets you set a background
# straight from a file's context menu.
# =============================================================================

mkdir -p /usr/bin \
         /usr/share/applications \
         /usr/share/icons/hicolor/scalable/apps \
         /usr/share/wallpapers/RaptorOS \
         /usr/share/kio/servicemenus

# ── Bundled Raptor-branded wallpapers ─────────────────────────────────────────
# Plain SVG files (not a full KPackage wallpaper bundle) — simple enough for
# this app's own gallery to scan directly, and still browsable/usable via any
# standard file picker including KDE's native wallpaper settings.
# All four use the same #33FF33-on-#0a0e12 palette as the rest of the HUD theme.

cat << 'SVGEOF' > /usr/share/wallpapers/RaptorOS/raptor-grid.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080">
  <defs>
    <radialGradient id="vign" cx="50%" cy="45%" r="75%">
      <stop offset="0%"  stop-color="#0d1512"/>
      <stop offset="100%" stop-color="#050807"/>
    </radialGradient>
    <linearGradient id="floorfade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%"   stop-color="#33FF33" stop-opacity="0"/>
      <stop offset="70%"  stop-color="#33FF33" stop-opacity="0"/>
      <stop offset="100%" stop-color="#33FF33" stop-opacity="0.10"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#vign)"/>
  <g stroke="#33FF33" stroke-width="1" opacity="0.10">
    <line x1="0" y1="180" x2="1920" y2="180"/>
    <line x1="0" y1="360" x2="1920" y2="360"/>
    <line x1="0" y1="540" x2="1920" y2="540"/>
    <line x1="0" y1="720" x2="1920" y2="720"/>
    <line x1="0" y1="900" x2="1920" y2="900"/>
    <line x1="240" y1="0" x2="240" y2="1080"/>
    <line x1="480" y1="0" x2="480" y2="1080"/>
    <line x1="720" y1="0" x2="720" y2="1080"/>
    <line x1="960" y1="0" x2="960" y2="1080"/>
    <line x1="1200" y1="0" x2="1200" y2="1080"/>
    <line x1="1440" y1="0" x2="1440" y2="1080"/>
    <line x1="1680" y1="0" x2="1680" y2="1080"/>
  </g>
  <rect width="1920" height="1080" fill="url(#floorfade)"/>
  <g stroke="#33FF33" stroke-width="2.5" fill="none" opacity="0.55">
    <path d="M 60 60 L 60 140 M 60 60 L 140 60"/>
    <path d="M 1860 60 L 1860 140 M 1860 60 L 1780 60"/>
    <path d="M 60 1020 L 60 940 M 60 1020 L 140 1020"/>
    <path d="M 1860 1020 L 1860 940 M 1860 1020 L 1780 1020"/>
  </g>
</svg>
SVGEOF

cat << 'SVGEOF' > /usr/share/wallpapers/RaptorOS/raptor-radar.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080">
  <defs>
    <radialGradient id="bg2" cx="72%" cy="50%" r="60%">
      <stop offset="0%"  stop-color="#0e1a14"/>
      <stop offset="100%" stop-color="#050806"/>
    </radialGradient>
    <radialGradient id="sweepglow" cx="72%" cy="50%" r="45%">
      <stop offset="0%"  stop-color="#33FF33" stop-opacity="0.14"/>
      <stop offset="60%" stop-color="#33FF33" stop-opacity="0.03"/>
      <stop offset="100%" stop-color="#33FF33" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg2)"/>
  <rect width="1920" height="1080" fill="url(#sweepglow)"/>
  <g stroke="#33FF33" fill="none">
    <circle cx="1382" cy="540" r="110" opacity="0.20" stroke-width="1"/>
    <circle cx="1382" cy="540" r="220" opacity="0.16" stroke-width="1"/>
    <circle cx="1382" cy="540" r="330" opacity="0.12" stroke-width="1"/>
    <circle cx="1382" cy="540" r="440" opacity="0.08" stroke-width="1"/>
  </g>
  <g stroke="#33FF33" stroke-width="0.75" opacity="0.14">
    <line x1="942" y1="540" x2="1822" y2="540"/>
    <line x1="1382" y1="100" x2="1382" y2="980"/>
  </g>
  <path d="M 1382 540 L 1382 100 A 440 440 0 0 1 1693 229 Z" fill="#33FF33" opacity="0.06"/>
  <circle cx="1382" cy="540" r="4" fill="#33FF33" opacity="0.7"/>
</svg>
SVGEOF

cat << 'SVGEOF' > /usr/share/wallpapers/RaptorOS/raptor-circuit.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="cbg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%"   stop-color="#0b120e"/>
      <stop offset="100%" stop-color="#050706"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#cbg)"/>
  <g stroke="#33FF33" fill="none" stroke-width="1.5" opacity="0.16" stroke-linecap="round">
    <path d="M 100 900 L 100 700 L 300 700 L 300 500"/>
    <path d="M 300 500 L 560 500 L 560 300"/>
    <path d="M 560 300 L 560 140 L 820 140"/>
    <path d="M 1920 240 L 1660 240 L 1660 420 L 1440 420"/>
    <path d="M 1440 420 L 1440 640 L 1220 640"/>
    <path d="M 1220 640 L 1220 860 L 980 860"/>
    <path d="M 100 200 L 260 200 L 260 60"/>
    <path d="M 1920 900 L 1780 900 L 1780 1020"/>
  </g>
  <g fill="#33FF33" opacity="0.35">
    <circle cx="300" cy="700" r="4"/>
    <circle cx="300" cy="500" r="4"/>
    <circle cx="560" cy="300" r="4"/>
    <circle cx="820" cy="140" r="4"/>
    <circle cx="1660" cy="420" r="4"/>
    <circle cx="1440" cy="640" r="4"/>
    <circle cx="1220" cy="860" r="4"/>
    <circle cx="260" cy="200" r="4"/>
  </g>
</svg>
SVGEOF

cat << 'SVGEOF' > /usr/share/wallpapers/RaptorOS/raptor-horizon.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="hbg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%"   stop-color="#080c0a"/>
      <stop offset="55%"  stop-color="#050706"/>
      <stop offset="100%" stop-color="#020302"/>
    </linearGradient>
    <linearGradient id="hline" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%"   stop-color="#33FF33" stop-opacity="0"/>
      <stop offset="50%"  stop-color="#33FF33" stop-opacity="0.55"/>
      <stop offset="100%" stop-color="#33FF33" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#hbg)"/>
  <line x1="0" y1="540" x2="1920" y2="540" stroke="url(#hline)" stroke-width="1.5"/>
  <g stroke="#33FF33" opacity="0.5" stroke-width="1.5">
    <line x1="940" y1="500" x2="940" y2="540"/>
    <line x1="980" y1="520" x2="980" y2="540"/>
    <line x1="940" y1="540" x2="905" y2="540"/>
    <line x1="1015" y1="540" x2="980" y2="540"/>
  </g>
  <circle cx="960" cy="540" r="3" fill="#33FF33" opacity="0.7"/>
</svg>
SVGEOF

echo "Bundled wallpapers written."

# ── raptor-wallpaper Python app ────────────────────────────────────────────────
cat << 'PYEOF' > /usr/bin/raptor-wallpaper
#!/usr/bin/env python3
"""Raptor Wallpaper — gallery-style wallpaper picker with KDE Plasma integration."""

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gtk, Adw, GLib, Gio, GdkPixbuf

import json
import os
import subprocess
import sys
import threading
from pathlib import Path

CONFIG_FILE = Path.home() / ".config" / "raptor-wallpaper.json"
BUNDLED_DIR = Path("/usr/share/wallpapers/RaptorOS")
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".webp", ".bmp", ".svg")

# KDE org.kde.image wallpaper plugin FillMode values.
FILL_MODES = [
    ("Fill",    0),   # Scaled and Cropped — fills the screen, may crop
    ("Fit",     2),   # Scaled, Keep Proportions — fits within screen, may letterbox
    ("Stretch", 1),   # Scaled — stretches to exactly fill, may distort
    ("Center",  3),   # Centered — no scaling
    ("Tile",    4),   # Tiled — repeats at original size
]


def load_config() -> dict:
    defaults = {"image": None, "fill_mode": 0}
    try:
        with open(CONFIG_FILE) as f:
            defaults.update(json.load(f))
    except Exception:
        pass
    return defaults


def save_config(cfg: dict):
    try:
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception as e:
        print(f"[raptor-wallpaper] could not save config: {e}", file=sys.stderr)


def scan_gallery_images():
    """Bundled Raptor wallpapers first, then anything in ~/Pictures and
    ~/Pictures/Wallpapers, most-recently-modified first within each group."""
    images = []

    if BUNDLED_DIR.is_dir():
        images.extend(sorted(
            p for p in BUNDLED_DIR.iterdir()
            if p.suffix.lower() in IMAGE_EXTS
        ))

    for folder in (Path.home() / "Pictures", Path.home() / "Pictures" / "Wallpapers"):
        if folder.is_dir():
            found = sorted(
                (p for p in folder.iterdir() if p.suffix.lower() in IMAGE_EXTS),
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
            images.extend(found)

    seen = set()
    unique = []
    for p in images:
        rp = str(p.resolve())
        if rp not in seen:
            seen.add(rp)
            unique.append(p)
    return unique


def apply_wallpaper(image_path, fill_mode):
    """Apply the wallpaper via KDE's scripting bridge (sets both Image and
    FillMode together). Falls back to plasma-apply-wallpaperimage — which
    sets the image only, with whatever fill mode Plasma currently has — if
    the scripting bridge is unavailable for any reason."""
    # The path is embedded in a JavaScript string that Plasma evaluates, and in
    # a URL. Both must be escaped: a filename containing a quote, backslash, '#'
    # or '%' used to break the script (or inject into it) and fail silently.
    import json
    from urllib.parse import quote
    image_url = "file://" + quote(os.path.abspath(image_path))
    try:
        fill = int(fill_mode)
    except (TypeError, ValueError):
        fill = 0
    script = f"""
var allDesktops = desktops();
for (var i = 0; i < allDesktops.length; i++) {{
    var d = allDesktops[i];
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", {json.dumps(image_url)});
    d.writeConfig("FillMode", {fill});
    d.reloadConfig();
}}
"""
    for qdbus_cmd in ("qdbus6", "qdbus"):
        try:
            result = subprocess.run(
                [qdbus_cmd, "org.kde.plasmashell", "/PlasmaShell",
                 "org.kde.PlasmaShell.evaluateScript", script],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                return True, "Wallpaper applied"
        except FileNotFoundError:
            continue
        except Exception:
            continue

    try:
        result = subprocess.run(
            ["plasma-apply-wallpaperimage", image_path],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return True, "Wallpaper applied (fit mode not changed — set manually if needed)"
    except Exception as e:
        return False, f"Could not apply wallpaper: {e}"

    return False, "Plasma is not responding — is a session running?"


class WallpaperCard(Gtk.Button):
    """A single clickable thumbnail in the gallery grid."""

    def __init__(self, image_path, on_select):
        super().__init__()
        self.image_path = image_path
        self.add_css_class("flat")
        self.add_css_class("card")
        self.set_size_request(240, 150)

        overlay = Gtk.Overlay()
        self.set_child(overlay)

        picture = Gtk.Picture()
        picture.set_content_fit(Gtk.ContentFit.COVER)
        picture.set_filename(str(image_path))
        overlay.set_child(picture)

        self.check = Gtk.Image.new_from_icon_name("object-select-symbolic")
        self.check.set_pixel_size(22)
        self.check.set_halign(Gtk.Align.END)
        self.check.set_valign(Gtk.Align.START)
        self.check.set_margin_top(6)
        self.check.set_margin_end(6)
        self.check.add_css_class("selected-check")
        self.check.set_visible(False)
        overlay.add_overlay(self.check)

        self.connect("clicked", lambda *_: on_select(self))

    def set_selected(self, selected):
        self.check.set_visible(selected)
        if selected:
            self.add_css_class("wallpaper-selected")
        else:
            self.remove_css_class("wallpaper-selected")


class RaptorWallpaperWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.set_title("Raptor Wallpaper")
        self.set_default_size(760, 620)

        self._cfg = load_config()
        self._selected_path = self._cfg.get("image")
        self._fill_mode = self._cfg.get("fill_mode", 0)
        self._cards = []

        self._build_ui()
        self._populate_gallery()

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)

        hb = Adw.HeaderBar()
        root.append(hb)

        browse_btn = Gtk.Button()
        browse_btn.set_child(Gtk.Image.new_from_icon_name("folder-open-symbolic"))
        browse_btn.set_tooltip_text("Browse for an image…")
        browse_btn.connect("clicked", self._on_browse_clicked)
        hb.pack_start(browse_btn)

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

        gallery_label = Gtk.Label(label="Choose a wallpaper", xalign=0)
        gallery_label.add_css_class("title-3")
        content.append(gallery_label)

        subtitle = Gtk.Label(
            label="Click any thumbnail to preview it, then Apply below. "
                  "Includes Raptor OS wallpapers and images from your Pictures folder.",
            xalign=0, wrap=True
        )
        subtitle.add_css_class("dim-label")
        content.append(subtitle)

        self.flow_box = Gtk.FlowBox()
        self.flow_box.set_valign(Gtk.Align.START)
        self.flow_box.set_max_children_per_line(4)
        self.flow_box.set_min_children_per_line(2)
        self.flow_box.set_selection_mode(Gtk.SelectionMode.NONE)
        self.flow_box.set_row_spacing(12)
        self.flow_box.set_column_spacing(12)
        content.append(self.flow_box)

        options_group = Adw.PreferencesGroup(title="Display Options")
        content.append(options_group)

        self.fill_row = Adw.ComboRow()
        self.fill_row.set_title("Fit mode")
        self.fill_row.set_subtitle("How the image fills your screen")
        fill_model = Gtk.StringList.new([name for name, _ in FILL_MODES])
        self.fill_row.set_model(fill_model)
        current_index = next(
            (i for i, (_, v) in enumerate(FILL_MODES) if v == self._fill_mode), 0
        )
        self.fill_row.set_selected(current_index)
        self.fill_row.connect("notify::selected", self._on_fill_mode_changed)
        options_group.add(self.fill_row)

        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btn_box.set_halign(Gtk.Align.CENTER)
        btn_box.set_margin_top(4)
        content.append(btn_box)

        self.apply_btn = Gtk.Button(label="Apply Wallpaper")
        self.apply_btn.add_css_class("suggested-action")
        self.apply_btn.add_css_class("pill")
        self.apply_btn.connect("clicked", self._on_apply_clicked)
        btn_box.append(self.apply_btn)

        self.spinner = Gtk.Spinner()
        btn_box.append(self.spinner)

        css = Gtk.CssProvider()
        css.load_from_string("""
            .wallpaper-selected {
                outline: 3px solid #33FF33;
                outline-offset: -3px;
                border-radius: 8px;
            }
            .selected-check {
                color: #33FF33;
                background-color: rgba(10, 14, 18, 0.75);
                border-radius: 999px;
                padding: 2px;
            }
        """)
        Gtk.StyleContext.add_provider_for_display(
            self.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    def _populate_gallery(self):
        for image_path in scan_gallery_images():
            self._add_card(image_path)

    def _add_card(self, image_path, select_after=False):
        card = WallpaperCard(image_path, self._on_card_selected)
        self.flow_box.append(card)
        self._cards.append(card)
        if select_after or str(image_path) == self._selected_path:
            self._select_card(card)
        return card

    def _on_card_selected(self, card):
        self._select_card(card)

    def _select_card(self, card):
        for c in self._cards:
            c.set_selected(c is card)
        self._selected_path = str(card.image_path)

    def _on_browse_clicked(self, _btn):
        dialog = Gtk.FileChooserDialog(
            title="Select an Image",
            transient_for=self,
            action=Gtk.FileChooserAction.OPEN,
        )
        dialog.add_buttons(
            "Cancel", Gtk.ResponseType.CANCEL,
            "Select", Gtk.ResponseType.OK,
        )
        image_filter = Gtk.FileFilter()
        image_filter.set_name("Images")
        for pattern in ("*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.svg"):
            image_filter.add_pattern(pattern)
        dialog.add_filter(image_filter)

        pictures = Path.home() / "Pictures"
        if pictures.is_dir():
            dialog.set_current_folder(Gio.File.new_for_path(str(pictures)))

        dialog.connect("response", self._on_file_chosen)
        dialog.present()

    def _on_file_chosen(self, dialog, response):
        if response == Gtk.ResponseType.OK:
            file = dialog.get_file()
            if file:
                path = Path(file.get_path())
                card = WallpaperCard(path, self._on_card_selected)
                self.flow_box.prepend(card)
                self._cards.insert(0, card)
                self._select_card(card)
        dialog.close()

    def _on_fill_mode_changed(self, row, _param):
        idx = row.get_selected()
        if 0 <= idx < len(FILL_MODES):
            self._fill_mode = FILL_MODES[idx][1]

    def _on_apply_clicked(self, _btn):
        if not self._selected_path or not Path(self._selected_path).exists():
            self._toast("Select a wallpaper first")
            return

        self.apply_btn.set_sensitive(False)
        self.spinner.start()

        def worker():
            ok, msg = apply_wallpaper(self._selected_path, self._fill_mode)
            if ok:
                save_config({"image": self._selected_path, "fill_mode": self._fill_mode})
            GLib.idle_add(self._on_apply_done, ok, msg)

        threading.Thread(target=worker, daemon=True).start()

    def _on_apply_done(self, ok, msg):
        self.spinner.stop()
        self.apply_btn.set_sensitive(True)
        self._toast(msg)

    def _toast(self, msg):
        toast = Adw.Toast.new(msg)
        toast.set_timeout(4)
        self.toast_overlay.add_toast(toast)


class RaptorWallpaperApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.cerberus9dev.raptorwallpaper")
        self.connect("activate", self.on_activate)

    def on_activate(self, app):
        win = RaptorWallpaperWindow(app)
        win.present()


def main():
    # --apply <path> : headless mode for the Dolphin right-click context menu.
    # Applies the given image immediately with the last-used fit mode and exits
    # — no window opens. This is what makes "right-click an image → set as
    # wallpaper" work the way it does in Windows Explorer.
    if len(sys.argv) >= 3 and sys.argv[1] == "--apply":
        image_path = os.path.abspath(sys.argv[2])
        cfg = load_config()
        ok, msg = apply_wallpaper(image_path, cfg.get("fill_mode", 0))
        if ok:
            save_config({"image": image_path, "fill_mode": cfg.get("fill_mode", 0)})
        print(msg)
        sys.exit(0 if ok else 1)

    app = RaptorWallpaperApp()
    app.run(sys.argv)


if __name__ == "__main__":
    main()
PYEOF
chmod +x /usr/bin/raptor-wallpaper

# Keep the old binary name as a symlink in case anything references it
ln -sf /usr/bin/raptor-wallpaper /usr/bin/raptor-wallpaper-manager

# ── .desktop launcher ─────────────────────────────────────────────────────────
cat << 'EOF' > /usr/share/applications/raptor-wallpaper.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=Raptor Wallpaper
GenericName=Wallpaper Picker
Comment=Browse and apply wallpapers — Raptor OS originals or your own images
Exec=/usr/bin/raptor-wallpaper
Icon=raptor-wallpaper
Terminal=false
Categories=X-RaptorOS;System;Settings;
Keywords=wallpaper;desktop;background;image;personalize;
StartupNotify=true
X-KDE-SubstituteUID=false
EOF

# ── Application icon ───────────────────────────────────────────────────────────
# Same visual language as raptor-cortex.svg — purple radial badge, dashed ring,
# cardinal ticks — with a mountains-and-sun picture glyph in the centre so the
# apps read as a matched family in the menu.
cat << 'SVGEOF' > /usr/share/icons/hicolor/scalable/apps/raptor-wallpaper.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#7c3aed"/>
      <stop offset="100%" stop-color="#4c1d95"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="url(#bg)"/>
  <circle cx="32" cy="32" r="24" fill="none" stroke="#a78bfa" stroke-width="1.5"
          stroke-dasharray="12 4" stroke-linecap="round"/>
  <line x1="32" y1="10" x2="32" y2="18" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="32" y1="46" x2="32" y2="54" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="10" y1="32" x2="18" y2="32" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="46" y1="32" x2="54" y2="32" stroke="#c4b5fd" stroke-width="2" stroke-linecap="round"/>
  <line x1="16.7" y1="16.7" x2="22.4" y2="22.4" stroke="#c4b5fd" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="41.6" y1="41.6" x2="47.3" y2="47.3" stroke="#c4b5fd" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="47.3" y1="16.7" x2="41.6" y2="22.4" stroke="#c4b5fd" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="22.4" y1="41.6" x2="16.7" y2="47.3" stroke="#c4b5fd" stroke-width="1.5" stroke-linecap="round"/>
  <rect x="21" y="22" width="22" height="20" rx="2" fill="white" opacity="0.95"/>
  <rect x="23.5" y="24.5" width="17" height="15" fill="url(#bg)"/>
  <circle cx="35.5" cy="28.5" r="2.2" fill="#c4b5fd"/>
  <path d="M 23.5 39.5 L 29 32 L 33 36 L 37 30 L 40.5 39.5 Z" fill="#c4b5fd"/>
</svg>
SVGEOF

gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── Dolphin right-click "Set as Raptor Wallpaper" ──────────────────────────────
# Right-click any image file in Dolphin → Set as Raptor Wallpaper → applies
# immediately with the last-used fit mode, no window opens. Mirrors the
# behaviour Windows Explorer has had for years and KDE has never shipped
# out of the box.
cat << 'EOF' > /usr/share/kio/servicemenus/raptor-set-wallpaper.desktop
[Desktop Entry]
Type=Service
X-KDE-ServiceTypes=KonqPopupMenu/Plugin
MimeType=image/png;image/jpeg;image/webp;image/bmp;image/svg+xml;image/avif;image/jxl;image/tiff;image/gif;
Actions=setRaptorWallpaper;
X-KDE-Priority=TopLevel

[Desktop Action setRaptorWallpaper]
Name=Set as Raptor Wallpaper
Icon=raptor-wallpaper
Exec=/usr/bin/raptor-wallpaper --apply %f
EOF

# ── Self-check ────────────────────────────────────────────────────────────────
# A malformed heredoc here can install a truncated binary or a missing .desktop
# entry, and the app then never appears in the launcher with an empty build log.
# Verify each artifact landed and is non-empty; fail the build if not.
RAPTOR_EXPECTED_PAYLOAD="
/usr/bin/raptor-wallpaper
/usr/share/applications/raptor-wallpaper.desktop
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "RAPTOR_WALLPAPER_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
echo "RAPTOR_WALLPAPER_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
echo "Raptor Wallpaper installed successfully."
