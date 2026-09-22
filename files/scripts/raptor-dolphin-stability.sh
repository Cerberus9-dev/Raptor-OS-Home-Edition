#!/bin/bash
set -oue pipefail

# ═════════════════════════════════════════════════════════════════════════════
# Raptor OS — Dolphin stability hardening (archive selection freeze/crash)
# ═════════════════════════════════════════════════════════════════════════════
# Selecting or right-clicking files makes Dolphin load every KFileItemAction
# plugin that agrees with the selection's MIME types, to decide which context
# actions to offer. Ark ships three such plugins — "Compress", "Extract" and
# the drag&drop extract — and all three advertise "application/octet-stream",
# so they are queried for virtually ANY selection, archive or not.
#
# To decide whether to show themselves each plugin then calls determineMimeType
# on EVERY selected file; on a big or many-file selection that per-file MIME
# scan blocks the UI for seconds (KDE bug 499551), and loading the kerfuffle
# plugins can segfault Dolphin outright (KDE bugs 482016, 420429). Disabling
# these context actions is the upstream-blessed workaround; it only removes the
# right-click "Compress/Extract…" entries. Double-clicking an archive to open
# it in Ark (wired up via raptor-mimeapps.list) is unaffected.
#
# On top of that, selecting an archive makes Dolphin compute its "Contents"
# through KFileMetaData's in-process archive extractor (libarchive / KF6Archive).
# On a big archive, or a slow/loaded disk, that blocking read wedges the UI —
# and if Baloo was running it queues behind baloo's own content reads (KDE bug
# 495145). We therefore also drop kfilemetadata's archive + AppImage extractors
# (AppImage is an ISO-level reader too), so selecting a .zip can never read the
# file's contents for metadata again. Ark keeps its own kerfuffle engine, so
# opening archives still works.
#
# KFileItemAction + kfilemetadata plugins can't be turned off through KPlugin
# config, so we drop the plugin .so (+ metadata .json) files from the image at
# build time. Both the lib64 and lib Qt6 plugin roots are covered for
# Fedora/Bazzite.
# ═════════════════════════════════════════════════════════════════════════════

PLUGIN_DIRS=(
    /usr/lib64/qt6/plugins/kf6/kfileitemaction
    /usr/lib/qt6/plugins/kf6/kfileitemaction
)

PLUGINS=(
    compressfileitemaction  # "Compress as ZIP / 7z…" context menu
    extractfileitemaction   # "Extract here / Extract to…" context menu
    ark_dndextract          # "Extract" drag-and-drop action
)

removed=0
for dir in "${PLUGIN_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue
    for plugin in "${PLUGINS[@]}"; do
        for ext in so json; do
            if [[ -f "${dir}/${plugin}.${ext}" ]]; then
                rm -f "${dir}/${plugin}.${ext}"
                echo "raptor-dolphin-stability: removed ${dir}/${plugin}.${ext}"
                removed=$((removed + 1))
            fi
        done
    done
done

echo "raptor-dolphin-stability: disabled Ark context-menu archive actions (${removed} files removed)."

# ── In-process archive metadata extractors (KFileMetaData) ──────────────────
# Name varies across distros (kfilemetadata_archiveextractor.so vs bare
# archiveextractor.so), so match by substring case-insensitively.
METADATA_DIRS=(
    /usr/lib64/qt6/plugins/kf6/kfilemetadata
    /usr/lib/qt6/plugins/kf6/kfilemetadata
)

for dir in "${METADATA_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        rm -f "${f}"
        echo "raptor-dolphin-stability: removed ${f}"
        removed=$((removed + 1))
    done < <(find "${dir}" -maxdepth 1 -type f \
        \( -iname '*archiveextractor*' -o -iname '*appimageextractor*' \))
done

if [[ "${removed}" -gt 0 ]]; then
    echo "raptor-dolphin-stability: archive metadata reading disabled (${removed} total files removed)."
fi