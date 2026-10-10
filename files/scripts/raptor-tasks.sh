#!/bin/bash
set -euo pipefail

# Raptor Tasks — simple task/todo manager with categories, persistence, and
# keyboard shortcuts. Inspired by CoyoteTM but minimal and GTK4/Adwaita native.

mkdir -p /usr/bin /usr/share/applications /usr/share/icons/hicolor/scalable/apps

# ── Python GUI ────────────────────────────────────────────────────────────────
cat << 'PYEOF' > /usr/bin/raptor-tasks
#!/usr/bin/env python3
"""Raptor Tasks — simple task manager with categories and persistence."""

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib, Gio

import json
import os
import sys
from pathlib import Path

CONFIG_FILE = Path.home() / ".config" / "raptor-tasks.json"

class Task:
    def __init__(self, text, category="Personal", done=False, id=None):
        self.id = id or int(GLib.DateTime.new_now_local().format("%s%f"))
        self.text = text
        self.category = category
        self.done = done

    def to_dict(self):
        return {"id": self.id, "text": self.text, "category": self.category, "done": self.done}

    @classmethod
    def from_dict(cls, d):
        t = cls(d["text"], d.get("category", "Personal"), d.get("done", False), d["id"])
        return t


CATEGORIES = ["Personal", "Work", "Gaming", "Shopping", "Ideas", "Other"]

def load_tasks():
    try:
        with open(CONFIG_FILE) as f:
            data = json.load(f)
        return [Task.from_dict(t) for t in data]
    except Exception:
        return []

def save_tasks(tasks):
    try:
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump([t.to_dict() for t in tasks], f, indent=2)
    except Exception as e:
        print(f"[raptor-tasks] could not save: {e}", file=sys.stderr)


class TaskRow(Adw.ActionRow):
    def __init__(self, task, on_toggle, on_delete, on_edit):
        super().__init__()
        self.task = task
        self.set_activatable(True)

        self.check = Gtk.CheckButton(active=task.done, valign=Gtk.Align.CENTER)
        self.check.connect("toggled", lambda *_: on_toggle(self))
        self.add_prefix(self.check)

        label = Gtk.Label(label=task.text, xalign=0, wrap=True)
        if task.done:
            label.add_css_class("dim-label")
        self.add_suffix(label)

        self.category_badge = Gtk.Label(label=task.category)
        self.category_badge.add_css_class("caption")
        self.category_badge.add_css_class("badge")
        self.add_suffix(self.category_badge)

        menu = Gtk.PopoverMenu.new_from_model(self._build_menu(on_edit, on_delete))
        menu_btn = Gtk.MenuButton()
        menu_btn.set_popover(menu)
        menu_btn.set_icon_name("open-menu-symbolic")
        menu_btn.add_css_class("flat")
        self.add_suffix(menu_btn)

        self.connect("activated", lambda *_: on_edit(self))

    def _build_menu(self, on_edit, on_delete):
        gio_menu = Gio.Menu()
        edit_item = Gio.MenuItem.new("Edit", "app.edit")
        delete_item = Gio.MenuItem.new("Delete", "app.delete")
        gio_menu.append_item(edit_item)
        gio_menu.append_item(delete_item)

        action_edit = Gio.SimpleAction.new("edit", None)
        action_edit.connect("activate", lambda *_: on_edit(self))
        action_delete = Gio.SimpleAction.new("delete", None)
        action_delete.connect("activate", lambda *_: on_delete(self))

        return gio_menu


class RaptorTasksWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.set_title("Raptor Tasks")
        self.set_default_size(500, 600)

        self.tasks = load_tasks()
        self._filtered_tasks = list(self.tasks)
        self._current_category = "All"

        self._build_ui()
        self._refresh_list()

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)

        hb = Adw.HeaderBar()
        root.append(hb)

        # Category filter
        self.cat_combo = Gtk.ComboBoxText()
        self.cat_combo.append("All", "All")
        for c in CATEGORIES:
            self.cat_combo.append(c, c)
        self.cat_combo.set_active(0)
        self.cat_combo.connect("changed", self._on_category_changed)
        hb.pack_start(self.cat_combo)

        # Add task button
        add_btn = Gtk.Button(icon_name="list-add-symbolic")
        add_btn.add_css_class("flat")
        add_btn.set_tooltip_text("Add task (Ctrl+N)")
        add_btn.connect("clicked", self._on_add_clicked)
        hb.pack_end(add_btn)

        self.toast_overlay = Adw.ToastOverlay()
        self.toast_overlay.set_vexpand(True)
        root.append(self.toast_overlay)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.toast_overlay.set_child(scroll)

        self.list_box = Gtk.ListBox()
        self.list_box.set_selection_mode(Gtk.SelectionMode.NONE)
        scroll.set_child(self.list_box)

        # Keyboard shortcuts
        self._setup_shortcuts()

    def _setup_shortcuts(self):
        # Ctrl+N = new task
        shortcut = Gtk.Shortcut.new(
            Gtk.ShortcutTrigger.parse_string("<Ctrl>n"),
            Gtk.CallbackAction.new(self._on_add_clicked, None)
        )
        self.add_shortcut(shortcut)

    def _on_category_changed(self, combo):
        self._current_category = combo.get_active_id() or "All"
        self._refresh_list()

    def _refresh_list(self):
        # Remove all rows
        child = self.list_box.get_first_child()
        while child:
            next_child = child.get_next_sibling()
            self.list_box.remove(child)
            child = next_child

        # Filter and add
        for task in self.tasks:
            if self._current_category == "All" or task.category == self._current_category:
                row = TaskRow(task, self._on_toggle, self._on_delete, self._on_edit)
                self.list_box.append(row)

    def _on_add_clicked(self, *_):
        dialog = TaskEditDialog(self, task=None, on_save=self._on_task_saved)
        dialog.present()

    def _on_edit(self, row):
        dialog = TaskEditDialog(self, task=row.task, on_save=self._on_task_saved)
        dialog.present()

    def _on_toggle(self, row):
        row.task.done = not row.task.done
        save_tasks(self.tasks)
        self._refresh_list()
        self._toast("Task " + ("completed" if row.task.done else "reopened"))

    def _on_delete(self, row):
        self.tasks = [t for t in self.tasks if t.id != row.task.id]
        save_tasks(self.tasks)
        self._refresh_list()
        self._toast("Task deleted")

    def _on_task_saved(self, task):
        existing = next((i for i, t in enumerate(self.tasks) if t.id == task.id), None)
        if existing is not None:
            self.tasks[existing] = task
        else:
            self.tasks.append(task)
        save_tasks(self.tasks)
        self._refresh_list()

    def _toast(self, msg):
        toast = Adw.Toast.new(msg)
        toast.set_timeout(2)
        self.toast_overlay.add_toast(toast)


class TaskEditDialog(Adw.Dialog):
    def __init__(self, parent, task, on_save):
        super().__init__(transient_for=parent, modal=True)
        self._on_save = on_save
        self._editing = task is not None
        self._task = task
        self.set_title("Edit Task" if self._editing else "New Task")
        self.set_default_size(400, 280)
        self._build_ui()

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_child(root)

        hb = Adw.HeaderBar()
        root.append(hb)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        content.set_margin_top(20)
        content.set_margin_bottom(20)
        content.set_margin_start(20)
        content.set_margin_end(20)
        root.append(content)

        group = Adw.PreferencesGroup()
        content.append(group)

        self.text_row = Adw.EntryRow(title="Task")
        self.text_row.set_text(self._task.text if self._task else "")
        group.add(self.text_row)

        self.cat_combo = Gtk.ComboBoxText()
        for c in CATEGORIES:
            self.cat_combo.append(c, c)
        current = self._task.category if self._task else "Personal"
        self.cat_combo.set_active_id(current)
        cat_row = Adw.ActionRow(title="Category")
        cat_row.add_suffix(self.cat_combo)
        group.add(cat_row)

        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        btn_box.set_halign(Gtk.Align.END)
        btn_box.set_margin_top(8)
        content.append(btn_box)

        cancel_btn = Gtk.Button(label="Cancel")
        cancel_btn.connect("clicked", lambda *_: self.close())
        btn_box.append(cancel_btn)

        save_btn = Gtk.Button(label="Save")
        save_btn.add_css_class("suggested-action")
        save_btn.connect("clicked", self._on_save_clicked)
        btn_box.append(save_btn)

    def _on_save_clicked(self, *_):
        text = self.text_row.get_text().strip()
        if not text:
            return
        category = self.cat_combo.get_active_id() or "Personal"
        if self._editing:
            self._task.text = text
            self._task.category = category
            saved = self._task
        else:
            saved = Task(text, category)
        self._on_save(saved)
        self.close()


class RaptorTasksApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="io.github.cerberus9dev.RaptorTasks")
        self.connect("activate", self.on_activate)

    def on_activate(self, app):
        win = RaptorTasksWindow(app)
        win.present()


def main():
    app = RaptorTasksApp()
    return app.run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod +x /usr/bin/raptor-tasks

# ── .desktop ──────────────────────────────────────────────────────────────────
cat << 'EOF' > /usr/share/applications/raptor-tasks.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=Raptor Tasks
GenericName=Task Manager
Comment=Simple todo list with categories — like CoyoteTM but native GTK4
Exec=/usr/bin/raptor-tasks
Icon=raptor-tasks
Terminal=false
Categories=X-RaptorOS;Utility;Office;
Keywords=tasks;todo;notes;reminders;coyotetm;
StartupNotify=true
X-KDE-SubstituteUID=false
EOF

# ── Icon ──────────────────────────────────────────────────────────────────────
cat << 'SVGEOF' > /usr/share/icons/hicolor/scalable/apps/raptor-tasks.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#059669"/>
      <stop offset="100%" stop-color="#047857"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="url(#bg)"/>
  <circle cx="32" cy="32" r="24" fill="none" stroke="#6ee7b7" stroke-width="1.5"
          stroke-dasharray="12 4" stroke-linecap="round"/>
  <rect x="16" y="18" width="32" height="28" rx="2" fill="none" stroke="#6ee7b7" stroke-width="2"/>
  <line x1="20" y1="28" x2="44" y2="28" stroke="#6ee7b7" stroke-width="2" stroke-linecap="round"/>
  <line x1="20" y1="34" x2="36" y2="34" stroke="#6ee7b7" stroke-width="2" stroke-linecap="round"/>
  <line x1="20" y1="40" x2="32" y2="40" stroke="#6ee7b7" stroke-width="2" stroke-linecap="round"/>
  <circle cx="48" cy="16" r="8" fill="#f59e0b"/>
  <line x1="48" y1="12" x2="48" y2="20" stroke="white" stroke-width="2" stroke-linecap="round"/>
  <line x1="44" y1="16" x2="52" y2="16" stroke="white" stroke-width="2" stroke-linecap="round"/>
</svg>
SVGEOF

gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── Self-check ────────────────────────────────────────────────────────────────
RAPTOR_EXPECTED_PAYLOAD="
/usr/bin/raptor-tasks
/usr/share/applications/raptor-tasks.desktop
"
raptor_missing=""
for raptor_f in $RAPTOR_EXPECTED_PAYLOAD; do
    [ -s "$raptor_f" ] || raptor_missing="$raptor_missing $raptor_f"
done
if [ -n "$raptor_missing" ]; then
    echo "RAPTOR_TASKS_PAYLOAD_MISSING:$raptor_missing" >&2
    exit 1
fi
echo "RAPTOR_TASKS_READY payload=$(echo $RAPTOR_EXPECTED_PAYLOAD | wc -w | tr -d ' ') files verified"
echo "Raptor Tasks installed successfully."
