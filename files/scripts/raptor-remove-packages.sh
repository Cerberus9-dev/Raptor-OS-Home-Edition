#!/bin/bash
set -ou pipefail

# =============================================================================
# Raptor OS — remove unwanted base-image packages (tolerant)
#
# This used to be the `remove:` list of the recipe's rpm-ostree module. That
# module aborts the WHOLE image build with
#     error: No installed package matches '<pkg>'
# as soon as one listed package is absent from the base image — which happens
# every time Bazzite drops or renames a package (e.g. cmake on Fedora 44).
# Here every package is checked first: absent ones are skipped, and a removal
# that fails (for example a dependency conflict) is a warning, not a failed
# build.
# =============================================================================

REMOVE=(
    tuned-ppd
    plasma-systemmonitor
    neovim
    tmux
    ripgrep
    fzf
    ninja-build
    meson
    podman
    podman-compose
    thunderbird
    variety
    btop
    gcc
    make
    cmake
    krita
    vlc
)

present=()
for pkg in "${REMOVE[@]}"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
        present+=("$pkg")
    else
        echo "skip (not in base image): $pkg"
    fi
done

if [[ ${#present[@]} -eq 0 ]]; then
    echo "Nothing to remove."
    exit 0
fi

echo "Removing: ${present[*]}"
if rpm-ostree override remove "${present[@]}"; then
    echo "OK: removed ${#present[@]} package(s)"
    exit 0
fi

# Batch failed (e.g. one package is required by another) — go one by one so a
# single conflict does not leave everything else installed.
echo "WARNING: batch removal failed, retrying one package at a time"
for pkg in "${present[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 || continue
    rpm-ostree override remove "$pkg" || echo "WARNING: could not remove $pkg — leaving it installed"
done
exit 0
