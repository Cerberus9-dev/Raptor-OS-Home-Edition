#!/usr/bin/env python3
"""Repo-wide payload validation.

Every Raptor app is a builder script that writes its real code through
heredocs. A broken heredoc (wrong terminator, unterminated quote) produces a
script that installs a truncated or syntactically invalid file — which shows up
on the user's machine as "the app won't open" with nothing in the build log.

This checks every installer in files/scripts/ by extracting the payloads and
running the right parser on each one:
  * `#!…/python*`  → py_compile
  * `#!…/bash|sh`  → bash -n
  * *.desktop      → required keys present, Exec= target is generated
  * *.policy / XML → xml parse
  * *.svg          → xml parse

Run:  python3 files/scripts/tests/test_payloads.py
"""
from __future__ import annotations

import py_compile
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
sys.path.insert(0, str(HERE))

from extract import extract_file  # noqa: E402

INSTALLERS = sorted(SCRIPTS.glob("*.sh"))


def _write(path: str, text: str) -> Path:
    dest = Path(tempfile.mkdtemp(prefix="raptor-payload-")) / Path(path).name
    dest.write_text(text)
    return dest


def _shebang(text: str) -> str:
    first = text.splitlines()[0] if text.splitlines() else ""
    return first if first.startswith("#!") else ""


_BIN_DIRS = ("/usr/bin", "/usr/local/bin", "/bin", "/usr/sbin", "/usr/libexec")


def _resolves(payload: dict[str, str], exec_target: str) -> bool:
    """Does an .desktop Exec= target correspond to a file this installer writes?

    Exec= may be absolute (`/usr/bin/raptor-update`) or a bare command name
    resolved through PATH (`raptor-wine %U` -> /usr/bin/raptor-wine), so
    accept either shape.
    """
    if exec_target in payload:
        return True
    if exec_target.startswith("/"):
        return False
    for install_path in payload:
        if install_path.startswith(_BIN_DIRS) and \
                Path(install_path).name == exec_target:
            return True
    return False


class TestInstallerPayloads(unittest.TestCase):
    """One test per installer, so a failure names the offending script."""

    def _check(self, installer: Path) -> None:
        name = installer.name
        payload = extract_file(installer)
        # Not every installer is a builder: raptor-dolphin-stability.sh only
        # writes config files, so an empty payload map is legitimate there.
        if not payload and "<< '" not in installer.read_text():
            return

        for install_path, text in payload.items():
            with self.subTest(payload=install_path):
                shebang = _shebang(text)
                suffix = Path(install_path).suffix

                if "python" in shebang:
                    dest = _write(install_path, text)
                    try:
                        py_compile.compile(str(dest), doraise=True, cfile=str(dest) + "c")
                    except py_compile.PyCompileError as exc:
                        self.fail(f"{name} -> {install_path} is not valid Python:\n{exc}")

                elif "bash" in shebang or "sh" in shebang:
                    dest = _write(install_path, text)
                    proc = subprocess.run(
                        ["bash", "-n", str(dest)], capture_output=True, text=True
                    )
                    if proc.returncode != 0:
                        self.fail(
                            f"{name} -> {install_path} is not valid bash:\n{proc.stderr}"
                        )

                elif suffix == ".desktop":
                    for key in ("[Desktop Entry]", "Type=", "Name=", "Exec="):
                        self.assertIn(key, text, f"{install_path}: missing {key}")
                    target = next(
                        ln for ln in text.splitlines() if ln.startswith("Exec=")
                    ).split("=", 1)[1].strip().split()[0]
                    self.assertTrue(
                        _resolves(payload, target),
                        f"{name}: desktop Exec={target} resolves to nothing this "
                        f"installer generates — the launcher would do nothing",
                    )

                elif suffix in (".policy", ".svg"):
                    try:
                        ET.fromstring(text)
                    except ET.ParseError as exc:
                        self.fail(f"{name} -> {install_path} is not valid XML:\n{exc}")

    def test_all_installers(self):
        for installer in INSTALLERS:
            with self.subTest(installer=installer.name):
                self._check(installer)

    def test_every_installer_is_wired_into_recipe(self):
        """An installer nothing references never runs — the app simply doesn't
        exist on the image, which is indistinguishable from a broken app."""
        recipe = (SCRIPTS.parent.parent / "recipes" / "recipe.yml").read_text()
        for installer in INSTALLERS:
            if installer.name == "brave-repo.sh":
                continue  # a source-repo helper, invoked by another script
            with self.subTest(installer=installer.name):
                self.assertIn(
                    installer.name,
                    recipe,
                    f"{installer.name} is not listed in recipe.yml — it will "
                    f"never run during the image build",
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
