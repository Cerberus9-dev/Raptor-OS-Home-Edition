#!/usr/bin/env python3
"""Extract the payload that the installer scripts generate via heredocs.

Every Raptor app is a *builder* script that writes its real payload to disk
with `cat << 'EOF' > /some/path`. That made the shipped logic impossible to
unit test: the thing that runs on the user's machine (the generated helper /
GUI) is a string literal inside a build script.

This module pulls those payloads out so tests can execute the exact bytes that
get installed, instead of a hand-copied approximation that drifts.

Supported forms:
    cat << 'EOF' > /abs/path            # literal heredoc
    cat << 'PYEOF' > /abs/path
    cat << 'EOF' >> /abs/path
    cat > /abs/path << 'EOF'
"""
from __future__ import annotations

import re
import shlex
from pathlib import Path

# cat [-] << 'WORD' > TARGET      |   cat > TARGET << 'WORD'
_HEREDOC = re.compile(
    r"^cat\s+(?:-\s+)?<<\s*'(?P<word>[A-Za-z_][A-Za-z0-9_]*)'\s*"
    r"(?P<rest>[^|;&]*)$"
)
# cat > TARGET << 'WORD'
_HEREDOC_REV = re.compile(
    r"^cat\s+(?P<rest>[^<]*?)<<\s*'(?P<word>[A-Za-z_][A-Za-z0-9_]*)'\s*$"
)
_TARGET = re.compile(r"(?P<op>>>|>)\s*(?P<path>[^\s]+)\s*$")


def _find_target(rest: str) -> tuple[str, str] | None:
    m = _TARGET.search(rest)
    if not m:
        return None
    return m.group("op"), m.group("path")


def extract(script_text: str) -> dict[str, str]:
    """Return {install_path: payload} for every heredoc-written file."""
    lines = script_text.splitlines()
    out: dict[str, str] = {}
    i = 0
    while i < len(lines):
        line = lines[i]
        m = _HEREDOC.match(line) or _HEREDOC_REV.match(line)
        if not m:
            i += 1
            continue
        word = m.group("word")
        found = _find_target(m.group("rest"))
        if not found:
            i += 1
            continue
        op, path = found
        body: list[str] = []
        i += 1
        while i < len(lines) and lines[i].strip() != word:
            body.append(lines[i])
            i += 1
        i += 1  # skip the terminator line
        text = "\n".join(body) + "\n"
        if op == ">":
            out[path] = text
        else:  # append
            out[path] = out.get(path, "") + text
    return out


def extract_file(path: str | Path) -> dict[str, str]:
    return extract(Path(path).read_text())


def shell_path(path: str) -> str:
    """The path as a test would want to materialise it (no leading /)."""
    return shlex.quote(path.lstrip("/"))


if __name__ == "__main__":
    import sys

    for k, v in extract_file(sys.argv[1]).items():
        print(f"{k}  ({len(v.splitlines())} lines)")
