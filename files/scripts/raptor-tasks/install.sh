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
    if not CONFIG_FILE.exists():
        return []
    try:
        with CONFIG_FILE.open(encoding="utf-8") as stream:
            data = json.load(stream)
        if not isinstance(data, list):
            raise ValueError("task file root must be a list")
        tasks = []
        for item in data:
            if not isinstance(item, dict) or not isinstance(item.get("text"), str):
                raise ValueError("invalid task entry")
            tasks.append(Task.from_dict(item))
        return tasks
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as exc:
        # Never silently treat a damaged file as an empty list: that could
        # overwrite a user's tasks on the next save.
        backup = CONFIG_FILE.with_suffix(".json.corrupt")
        suffix = 1
        while backup.exists():
            backup = CONFIG_FILE.with_suffix(f".json.corrupt.{suffix}")
            suffix += 1
        try:
            CONFIG_FILE.replace(backup)
            print(f"[raptor-tasks] unreadable task data preserved at {backup}: {exc}", file=sys.stderr)
        except OSError as backup_error:
            print(f"[raptor-tasks] could not read task data ({exc}) or preserve it ({backup_error})", file=sys.stderr)
        return []

def save_tasks(tasks):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = CONFIG_FILE.with_suffix(".json.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as stream:
            json.dump([task.to_dict() for task in tasks], stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(CONFIG_FILE)
        return True
    except OSError as exc:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        print(f"[raptor-tasks] could not save: {exc}", file=sys.stderr)
        return False


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
        edit_item = Gio.MenuItem.new("Edit", "row.edit")
        delete_item = Gio.MenuItem.new("Delete", "row.delete")
        gio_menu.append_item(edit_item)
        gio_menu.append_item(delete_item)

        action_edit = Gio.SimpleAction.new("edit", None)
        action_edit.connect("activate", lambda *_: on_edit(self))
        action_delete = Gio.SimpleAction.new("delete", None)
        action_delete.connect("activate", lambda *_: on_delete(self))

        # The actions used to be created but never registered anywhere, so the menu items
        # pointed at actions that did not exist and GTK showed them disabled: Delete (and
        # Edit from the menu) could never work. Register them on this row under the "row"
        # prefix (not "app", which belongs to the application).
        group = Gio.SimpleActionGroup()
        group.add_action(action_edit)
        group.add_action(action_delete)
        self.insert_action_group("row", group)

        return gio_menu


class RaptorTasksWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app)
        self.set_title("Raptor Tasks")
        self.set_default_size(500, 600)

        self.tasks = load_tasks()
        self._filtered_tasks = list(self.tasks)
        self._current_category = "All"
        self._current_status = "All"
        self._search_text = ""

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

        # Status filter
        self.status_combo = Gtk.ComboBoxText()
        for status in ("All", "Open", "Completed"):
            self.status_combo.append(status, status)
        self.status_combo.set_active_id("All")
        self.status_combo.set_tooltip_text("Filter by task status")
        self.status_combo.connect("changed", self._on_status_changed)
        hb.pack_start(self.status_combo)

        # Add task button
        add_btn = Gtk.Button(icon_name="list-add-symbolic")
        add_btn.add_css_class("flat")
        add_btn.set_tooltip_text("Add task (Ctrl+N)")
        add_btn.connect("clicked", self._on_add_clicked)
        hb.pack_end(add_btn)

        self.toast_overlay = Adw.ToastOverlay()
        self.toast_overlay.set_vexpand(True)
        root.append(self.toast_overlay)

        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.toast_overlay.set_child(body)

        self.summary_label = Gtk.Label(xalign=0)
        self.summary_label.add_css_class("dim-label")
        self.summary_label.set_margin_start(16)
        self.summary_label.set_margin_end(16)
        self.summary_label.set_margin_top(8)
        self.summary_label.set_margin_bottom(4)
        body.append(self.summary_label)

        self.search_entry = Gtk.SearchEntry()
        self.search_entry.set_placeholder_text("Search tasks…")
        self.search_entry.set_margin_start(12)
        self.search_entry.set_margin_end(12)
        self.search_entry.connect("search-changed", self._on_search_changed)
        body.append(self.search_entry)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        body.append(scroll)

        self.list_box = Gtk.ListBox()
        self.list_box.set_selection_mode(Gtk.SelectionMode.NONE)
        self.list_box.add_css_class("boxed-list")
        empty = Adw.StatusPage()
        empty.set_icon_name("view-list-symbolic")
        empty.set_title("No tasks yet")
        empty.set_description("Add a task to start organizing your day.")
        self.empty_page = empty
        self.list_box.set_placeholder(self.empty_page)
        scroll.set_child(self.list_box)

        # Keyboard shortcuts
        self._setup_shortcuts()

    def _setup_shortcuts(self):
        # Ctrl+N = new task
        shortcut = Gtk.Shortcut.new(
            Gtk.ShortcutTrigger.parse_string("<Ctrl>n"),
            Gtk.CallbackAction.new(self._on_add_clicked, None)
        )
        controller = Gtk.ShortcutController()
        controller.set_scope(Gtk.ShortcutScope.LOCAL)
        controller.add_shortcut(shortcut)
        self.add_controller(controller)

    def _on_category_changed(self, combo):
        self._current_category = combo.get_active_id() or "All"
        self._refresh_list()

    def _on_status_changed(self, combo):
        self._current_status = combo.get_active_id() or "All"
        self._refresh_list()

    def _on_search_changed(self, entry):
        self._search_text = entry.get_text().strip().casefold()
        self._refresh_list()

    def _refresh_list(self):
        # Remove all rows
        child = self.list_box.get_first_child()
        while child:
            next_child = child.get_next_sibling()
            self.list_box.remove(child)
            child = next_child

        # Keep active tasks prominent; apply category, status, and text filters.
        visible = []
        for task in self.tasks:
            if self._current_category != "All" and task.category != self._current_category:
                continue
            if self._current_status == "Open" and task.done:
                continue
            if self._current_status == "Completed" and not task.done:
                continue
            if self._search_text and self._search_text not in (task.text + " " + task.category).casefold():
                continue
            visible.append(task)

        visible.sort(key=lambda task: (task.done, str(task.text).casefold()))
        completed = sum(1 for task in self.tasks if task.done)
        total = len(self.tasks)
        self.summary_label.set_text(
            f"{total - completed} open   •   {completed} completed   •   {total} total"
        )
        if total == 0:
            self.empty_page.set_title("No tasks yet")
            self.empty_page.set_description("Add a task to start organizing your day.")
        elif not visible:
            self.empty_page.set_title("No matching tasks")
            self.empty_page.set_description("Try another search or change the category/status filters.")
        for task in visible:
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
        if not save_tasks(self.tasks):
            row.task.done = not row.task.done
            self._toast("Couldn't save changes — check file permissions")
            return
        self._refresh_list()
        self._toast("Task " + ("completed" if row.task.done else "reopened"))

    def _on_delete(self, row):
        previous = list(self.tasks)
        self.tasks = [t for t in self.tasks if t.id != row.task.id]
        if not save_tasks(self.tasks):
            self.tasks = previous
            self._toast("Couldn't save changes — task was not deleted")
            return
        self._refresh_list()
        self._toast("Task deleted")

    def _on_task_saved(self, task):
        existing = next((i for i, t in enumerate(self.tasks) if t.id == task.id), None)
        if existing is not None:
            self.tasks[existing] = task
        else:
            self.tasks.append(task)
        if not save_tasks(self.tasks):
            self._toast("Couldn't save task — check file permissions")
            return False
        self._refresh_list()
        return True

    def _toast(self, msg):
        toast = Adw.Toast.new(msg)
        toast.set_timeout(2)
        self.toast_overlay.add_toast(toast)


class TaskEditDialog(Adw.Window):   # not Adw.Dialog: that has no transient_for/modal/set_default_size and present() needs a parent
    def __init__(self, parent, task, on_save):
        super().__init__(transient_for=parent, modal=True)
        self._on_save = on_save
        self._editing = task is not None
        # Edit a working copy. If the atomic save fails, the in-memory task
        # remains unchanged and the user can retry without losing old values.
        self._task = Task(task.text, task.category, task.done, task.id) if task else None
        self.set_title("Edit Task" if self._editing else "New Task")
        self.set_default_size(400, 280)
        self._build_ui()

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_content(root)

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
        if self._on_save(saved) is not False:
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
      <stop offset="0%" stop-color="#203d52"/>
      <stop offset="100%" stop-color="#0b1118"/>
    </radialGradient>
  </defs>
  <circle cx="32" cy="32" r="30" fill="url(#bg)"/>
  <circle cx="32" cy="32" r="24" fill="none" stroke="#8bd4f1" stroke-width="1.5"
          stroke-dasharray="12 4" stroke-linecap="round"/>
  <rect x="16" y="18" width="32" height="28" rx="2" fill="none" stroke="#8bd4f1" stroke-width="2"/>
  <line x1="20" y1="28" x2="44" y2="28" stroke="#8bd4f1" stroke-width="2" stroke-linecap="round"/>
  <line x1="20" y1="34" x2="36" y2="34" stroke="#8bd4f1" stroke-width="2" stroke-linecap="round"/>
  <line x1="20" y1="40" x2="32" y2="40" stroke="#8bd4f1" stroke-width="2" stroke-linecap="round"/>
  <circle cx="48" cy="16" r="8" fill="#f5b85c"/>
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
