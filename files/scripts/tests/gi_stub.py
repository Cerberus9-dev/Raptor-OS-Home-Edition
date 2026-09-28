"""Minimal `gi` stub so the generated Raptor GUIs are importable in tests.

Only what module-level class definitions need: `gi.require_version`, the
`Gtk`/`Adw`/`GLib` namespaces, and a few classes the app subclasses. Any
*call* into GTK raises, so a test can never accidentally pass by "rendering"
something — it must exercise the pure decision logic instead.
"""
from __future__ import annotations

import sys
import types


def _namespace(name: str) -> types.ModuleType:
    mod = types.ModuleType(name)

    class _Base:
        def __init__(self, *a, **kw):
            raise AssertionError(
                f"GTK object construction in a unit test: {name}.{self.__class__.__name__}"
            )

    def _mk(attr: str):
        def _raise(*a, **kw):
            raise AssertionError(f"GTK call in a unit test: {name}.{attr}()")
        return _raise

    for attr in (
        "Application", "ApplicationWindow", "Window", "Box", "Button", "Label",
        "Spinner", "ListBox", "ListBoxRow", "HeaderBar", "StatusPage", "Dialog",
        "InfoBar", "ScrolledWindow", "Separator", "ToggleButton", "Entry",
        "ProgressBar", "Banner", "Toast", "ToastOverlay", "ApplicationWindow",
    ):
        setattr(mod, attr, type(attr, (_Base,), {}))
    for attr in ("idle_add", "timeout_add", "source_remove"):
        setattr(mod, attr, _mk(attr))
    mod.MAIN = 1
    return mod


def install() -> None:
    gi = types.ModuleType("gi")
    gi.require_version = lambda ns, ver: None
    gi_repository = types.ModuleType("gi.repository")
    for ns in ("Gtk", "Adw", "GLib", "Gdk", "Gio"):
        setattr(gi_repository, ns, _namespace(ns))
    gi.repository = gi_repository
    sys.modules["gi"] = gi
    sys.modules["gi.repository"] = gi_repository
