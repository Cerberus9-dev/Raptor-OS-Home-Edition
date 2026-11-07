#!/bin/bash
set -euo pipefail

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
# opening archives still works. The image explicitly installs Ark, 7-Zip and
# Info-ZIP unzip, and maps common ZIP MIME aliases to Ark so opening an archive
# from the desktop does not route it back into Dolphin (KDE bug 528054).
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

if ! command -v ark >/dev/null 2>&1; then
    echo "raptor-dolphin-stability: Ark is required for the configured archive associations" >&2
    exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
    echo "raptor-dolphin-stability: unzip backend is missing" >&2
    exit 1
fi

echo "raptor-dolphin-stability: applied targeted Ark context-menu workaround (${removed} plugin files removed); Ark and unzip are available."

# Ark is the dedicated archive application. Keep its executable and MIME handlers
# available even when the known slow context-menu plugins are disabled.

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


# ── Raptor-owned KIO service menus ──────────────────────────────────────────
# Replace the removed upstream Ark context-menu plugins with small service
# entries that call Ark's documented CLI directly. This keeps archive actions
# available without loading the per-selection MIME-scanning plugins.
SERVICE_MENU_DIR=/usr/share/kio/servicemenus
install -d "$SERVICE_MENU_DIR"

cat > "$SERVICE_MENU_DIR/raptor-ark-extract.desktop" <<'ARK_EXTRACT'
[Desktop Entry]
Type=Service
Name=Raptor Archive
Icon=ark
TryExec=ark
X-KDE-Submenu=Raptor Archive
X-KDE-Protocols=file
X-KDE-RequiredNumberOfUrls=1
MimeType=application/zip;application/x-zip;application/x-zip-compressed;application/x-tar;application/x-compressed-tar;application/x-7z-compressed;application/x-rar;application/vnd.rar;application/x-rar-compressed;application/x-bzip;application/x-bzip2;application/x-bzip-compressed-tar;application/gzip;application/x-gzip;application/x-xz;application/x-lzma;application/x-lzip;application/x-zstd;application/zstd;application/x-cpio;application/x-archive;application/x-iso9660-image;application/x-cd-image;application/vnd.ms-cab-compressed;application/x-rpm;application/vnd.debian.binary-package;application/java-archive;application/x-cbz;application/x-cbr;application/vnd.comicbook+zip;application/vnd.comicbook-rar;
Actions=extractHere;extractTo;

[Desktop Action extractHere]
Name=Extract Here (into a folder)
Icon=ark
Exec=ark --batch --autodestination --autosubfolder %F

[Desktop Action extractTo]
Name=Extract To…
Icon=ark
Exec=ark --batch --dialog %F
ARK_EXTRACT
chmod 0755 "$SERVICE_MENU_DIR/raptor-ark-extract.desktop"

cat > "$SERVICE_MENU_DIR/raptor-ark-create.desktop" <<'ARK_CREATE'
[Desktop Entry]
Type=Service
Name=Raptor Archive
Icon=ark
TryExec=ark
X-KDE-Submenu=Raptor Archive
X-KDE-Protocols=file
X-KDE-MinNumberOfUrls=1
MimeType=application/*;audio/*;font/*;image/*;inode/directory;message/*;model/*;multipart/*;text/*;video/*;x-content/*;
Actions=createArchive;

[Desktop Action createArchive]
Name=Create Archive…
Icon=ark
Exec=ark --add %F
ARK_CREATE
chmod 0755 "$SERVICE_MENU_DIR/raptor-ark-create.desktop"

echo "raptor-dolphin-stability: installed Raptor-owned Ark extract/create context actions."
