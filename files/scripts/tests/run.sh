#!/usr/bin/env bash
# Run the Raptor OS payload + behaviour tests.
#
# These execute the exact code the installer scripts write to disk (extracted
# from their heredocs) with stubbed rpm-ostree / sudo / skopeo, so the logic
# that runs on a user's machine is verified before the image is built.
#
# Usage:  files/scripts/tests/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Python syntax of every test helper"
python3 -m py_compile "$HERE"/*.py

echo "==> Unit tests"
# Discover tests rather than listing them: a hardcoded list silently skips any
# new test file, which is exactly how a broken test can look green in CI.
for test_file in "$HERE"/test_*.py; do
    echo "    -- $(basename "$test_file")"
    python3 "$test_file"
done

echo "==> Shell syntax of every installer"
for installer in "$HERE"/../*.sh; do
    bash -n "$installer" || { echo "FAIL: $installer" >&2; exit 1; }
    echo "    ok  $(basename "$installer")"
done

echo
echo "All Raptor OS tests passed."
