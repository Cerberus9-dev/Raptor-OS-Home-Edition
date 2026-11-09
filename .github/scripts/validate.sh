#!/bin/bash
set -euo pipefail

echo "=== Validating installer scripts ==="

# Check all installer scripts exist and have valid syntax
for script in files/scripts/*/install.sh; do
    if ! bash -n "$script"; then
        echo "FAIL: $script has syntax error"
        exit 1
    fi
    echo "OK: $script"
done

# Check system files
for script in files/system_files/raptor-*.sh; do
    if ! bash -n "$script"; then
        echo "FAIL: $script has syntax error"
        exit 1
    fi
    echo "OK: $script"
done

# Check recipe.yml references existing scripts (only the script section)
echo "=== Checking recipe.yml script references ==="
in_scripts_section=false
while IFS= read -r line; do
    if [[ "$line" =~ "Custom build scripts" ]]; then
        in_scripts_section=true
        continue
    fi
    if [[ "$in_scripts_section" == true ]]; then
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*type:[[:space:]]*systemd ]]; then
            break
        fi
        if [[ "$line" =~ -[[:space:]]*(raptor-|shroudly-) ]]; then
            script_name=$(echo "$line" | sed 's/.*- //')
            if [[ ! -f "files/scripts/$script_name" ]]; then
                echo "FAIL: Recipe references missing script: $script_name"
                exit 1
            fi
        fi
    fi
done < recipes/recipe.yml

# Check every file the recipe copies into the image exists in the repo. A missing source
# aborts the whole image build at the 'files' module ("does not exist in /tmp/files").
echo "=== Checking recipe.yml file sources exist ==="
missing=0
while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    if [[ ! -e "files/$src" ]]; then
        echo "FAIL: recipe copies a file that is not in the repo: $src"
        missing=1
    fi
done < <(grep -E '^[[:space:]]*-?[[:space:]]*source:' recipes/recipe.yml | sed -E "s/.*source:[[:space:]]*//; s/[\"']//g")
if [[ "$missing" -ne 0 ]]; then
    exit 1
fi

# Guard the cross-component contracts that keep low-memory, audio, gaming,
# power-profile, update and ISO behavior working together.
assert_contains() {
    local file="$1" needle="$2"
    if ! grep -Fq -- "$needle" "$file"; then
        echo "FAIL: expected '$needle' in $file"
        exit 1
    fi
}
assert_not_contains() {
    local file="$1" needle="$2"
    if grep -Fq -- "$needle" "$file"; then
        echo "FAIL: unexpected '$needle' in $file"
        exit 1
    fi
}

echo "=== Checking power-profile and Cortex contracts ==="
assert_contains recipes/recipe.yml "- power-profiles-daemon.service"
assert_contains files/scripts/raptor-cortex/install.sh "def _sync_external_power_mode"
assert_contains files/scripts/raptor-cortex/install.sh "def _do_one_click_boost"
assert_contains files/scripts/raptor-cortex/install.sh "ACTUAL_PROFILE"
assert_contains files/scripts/raptor-cortex/install.sh '"drkonqi"'

echo "=== Checking memory, audio and browser contracts ==="
# ZRAM defaults are validated below against the low-CPU LZ4 configuration.
assert_contains files/system_files/99-raptor-wireplumber-alsa.conf "resample.quality                = 10"
assert_contains files/scripts/raptor-gaming/install.sh "org.mozilla.firefox/.mozilla/firefox"
assert_contains files/scripts/raptor-gaming/install.sh "flatpak run com.brave.Browser"
assert_not_contains files/scripts/raptor-gaming/install.sh "ln -sf /dev/null /etc/systemd/system/ModemManager.service"
assert_contains files/scripts/raptor-gaming/install.sh "cat << 'BRAVELAUNCHER'"
assert_contains files/scripts/raptor-gaming/install.sh "cat << 'TRIMMER'"
for marker in "cat << 'BRAVELAUNCHER'" "cat << 'TRIMMER'" 'echo "GAMING_READY'; do
    count="$(grep -Fc -- "$marker" files/scripts/raptor-gaming/install.sh)"
    if [[ "$count" -ne 1 ]]; then
        echo "FAIL: expected exactly one '$marker' marker in raptor-gaming installer; found $count"
        exit 1
    fi
done

echo "=== Checking normal Wine + optional Proton integration ==="
assert_contains recipes/recipe.yml "- wine"
assert_contains recipes/recipe.yml "- wine-mono"
assert_contains recipes/recipe.yml "- mingw32-wine-gecko"
assert_contains recipes/recipe.yml "- mingw64-wine-gecko"
assert_contains recipes/recipe.yml "- winetricks"
assert_contains recipes/recipe.yml "- umu-launcher"
assert_contains files/scripts/raptor-wine/install.sh "exec wine"
assert_contains files/scripts/raptor-wine/install.sh 'umu-run "${launch_command[@]}"'
assert_contains files/scripts/raptor-wine/install.sh 'umu-run ""'
assert_contains files/scripts/raptor-wine/install.sh 'target="$1"'
assert_not_contains files/scripts/raptor-wine/install.sh 'RAPTOR_WINE_ERROR: UMU is not installed'
assert_contains files/scripts/raptor-wine/install.sh '*.msi)'
assert_contains files/scripts/raptor-wine/install.sh 'msiexec.exe'
assert_not_contains files/scripts/raptor-wine/install.sh 'exec umu-run wine msiexec'
assert_contains files/scripts/raptor-wine/install.sh 'shift'
assert_contains files/scripts/raptor-wine/install.sh 'raptor-wine-proton program.exe [arguments...]'
# Visible app-menu entries launch a file picker; hidden desktop handlers own MIME opens.
assert_contains files/scripts/raptor-wine/install.sh 'Exec=raptor-wine-manager'
assert_contains files/scripts/raptor-wine/install.sh 'Exec=raptor-proton-manager'
assert_contains files/scripts/raptor-wine/install.sh 'Exec=raptor-proton-prefix-manager'
assert_contains files/scripts/raptor-wine/install.sh 'Exec=raptor-wine-open %f'
assert_contains files/scripts/raptor-wine/install.sh 'Exec=raptor-proton-open %f'
assert_contains files/scripts/raptor-wine/install.sh 'protontricks-launch --appid'
assert_contains files/scripts/raptor-wine/install.sh 'raptor-proton-prefix-open'
assert_contains files/scripts/raptor-wine/install.sh 'raptor-wine-associations'
assert_contains files/scripts/raptor-wine/install.sh 'NoDisplay=true'
assert_contains files/scripts/raptor-wine/install.sh "zenity"
assert_not_contains files/scripts/raptor-wine/install.sh "wineboot -u"
assert_not_contains files/scripts/raptor-wine/install.sh "winetricks --unattended"
assert_contains files/system_files/raptor-mimeapps.list "application/x-ms-dos-executable=raptor-wine-open.desktop"
assert_contains files/system_files/raptor-mimeapps.list "application/x-msi=raptor-wine-open.desktop"
assert_not_contains files/system_files/10-raptor-wine.conf "WINEESYNC=1"
assert_not_contains files/system_files/10-raptor-wine.conf "WINEFSYNC=1"
assert_contains files/system_files/10-raptor-wine.conf "WINEDEBUG=-all,+err"
assert_contains files/scripts/raptor-wine/install.sh 'export UMU_LOG="${UMU_LOG:-1}"'
assert_contains files/scripts/raptor-wine/install.sh "Raptor compatibility launch diagnostics"
assert_contains files/scripts/raptor-wine/install.sh 'log="$state_dir/${mode}-${stamp}-$$.log"'
assert_contains files/scripts/raptor-wine/install.sh 'chmod 600 "$log"'
assert_not_contains files/scripts/raptor-wine/install.sh '${stamp}-$.log"'
assert_contains files/scripts/raptor-wine/install.sh "wine --version"
assert_contains files/scripts/raptor-wine/install.sh "umu-run --version"
assert_contains files/scripts/raptor-wine/install.sh "stat -Lc 'Permissions: %A (%a)  Size: %s bytes'"

echo "=== Checking first-boot recovery contracts ==="
assert_contains files/system_files/raptor-browser-choice.sh "browser choice deferred; it will retry on the next login"
assert_contains files/system_files/raptor-chat-choice.sh "chat client choice deferred; it will retry on the next login"
assert_contains files/system_files/raptor-app-choice.sh "app selection deferred; it will retry on the next login"
bash -n files/system_files/raptor-app-choice.sh
assert_contains files/system_files/raptor-app-choice.sh 'Exec=/usr/bin/raptor-app-choice.sh --reopen'
assert_contains files/system_files/raptor-app-choice.sh 'if [[ -f "${STAMP_FILE}" && "${REOPEN}" -ne 1 ]]'
assert_contains files/system_files/raptor-app-choice.sh 'if [[ "${REOPEN}" -ne 1 ]]; then touch "${STAMP_FILE}"; fi'
assert_contains files/system_files/raptor-app-choice.sh '--search-column=3'
assert_contains files/system_files/raptor-app-choice.sh 'org.kde.kdeconnect'
assert_not_contains files/system_files/raptor-browser-choice.sh "Writing stamp to avoid loop"
assert_not_contains files/system_files/raptor-chat-choice.sh "Writing stamp to avoid loop"
assert_not_contains files/system_files/raptor-app-choice.sh "Writing stamp to avoid loop"
assert_not_contains files/system_files/raptor-firstboot.service "SuccessExitStatus=0 1"

echo "=== Checking Update Manager contracts ==="
assert_contains files/scripts/raptor-update/install.sh "from queue import Queue, Empty"
assert_contains files/scripts/raptor-update/install.sh 'flatpak", "update", "--user'
assert_contains files/scripts/raptor-update/install.sh "trap restore_wifi_power_save EXIT"
assert_contains files/scripts/raptor-update/install.sh "UPDATE_MANAGER_SHELL_SYNTAX_ERROR"
assert_contains files/scripts/raptor-update/install.sh "def stream_process"
assert_contains files/scripts/raptor-update/install.sh "CHECK_TIMEOUT         = 1860"
assert_contains files/scripts/raptor-update/install.sh "start_new_session=True"
assert_contains files/scripts/raptor-update/install.sh "os.killpg"
assert_contains files/scripts/raptor-update/install.sh "timeout=3 * 60 * 60"
assert_contains files/scripts/raptor-update/install.sh "timeout=900"
assert_contains files/scripts/raptor-update/install.sh 'rpm-ostree upgrade 2>&1 | tee "$out"'
assert_contains files/scripts/raptor-update/install.sh "_stop_process_group(helper)"
assert_contains .github/workflows/build.yml 'cargo build --release --workspace --manifest-path files/scripts/raptor-music/Cargo.toml'
assert_contains .github/workflows/build.yml 'cargo test --workspace --manifest-path files/scripts/raptor-music/Cargo.toml'
assert_contains .github/workflows/build.yml 'test -x files/staging/raptor-music'
assert_contains .github/workflows/build.yml 'test -x files/staging/raptor-shroudly'
assert_contains .github/workflows/build.yml 'Verify both apps inside the published image'
assert_not_contains .github/workflows/build.yml 'PR validation only: built Raptor Music without staging it into the image.'
assert_not_contains files/scripts/raptor-update/install.sh "for line in user_proc.stdout"
assert_not_contains files/scripts/raptor-update/install.sh "for line in fp_proc.stdout"

echo "=== Checking Raptor Music desktop experience ==="
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'preferred-width: 1180px;'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'preferred-height: 760px;'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'import { Button, LineEdit, ListView, Slider }'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'LineEdit {'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'placeholder-text: "Songs, artists, albums or genres";'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'min-width: 860px;'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'Explore Audius'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'Local matches update as you type'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'vertical-stretch: 1;'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/src/main.rs 'parse_audius_tracks'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/src/main.rs 'https://api.audius.co/v1/users/search'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/src/main.rs 'ui.on_artist_selected'
assert_contains files/scripts/raptor-music/crates/raptor-desktop/ui/main.slint 'online_artist_list'

echo "=== Checking low-memory application defaults ==="
assert_contains files/scripts/raptor-gaming/install.sh '"Value": 32768,'
assert_contains files/scripts/raptor-gaming/install.sh '"Value": 2,'
assert_contains files/scripts/raptor-gaming/install.sh 'user_pref("dom.ipc.processCount", 2);'
assert_contains files/system_files/raptor-app-choice.sh '--renderer-process-limit=4'
assert_contains files/system_files/raptor-app-choice.sh 'discord-flags.conf'
assert_contains files/system_files/raptor-app-choice.sh 'touch "$VESKTOP_FLAGS"'
assert_contains files/system_files/raptor-app-choice.sh 'touch "$EQUIBOP_CFG"'
assert_contains files/system_files/raptor-app-choice.sh "grep -q '^--renderer-process-limit='"
assert_contains files/system_files/raptor-app-choice.sh 'Raptor OS low-memory renderer default'
assert_contains files/system_files/raptor-app-choice.sh 'DISCORD_FLAGS="$DISCORD_CFG/discord-flags.conf"'
assert_contains files/system_files/raptor-app-choice.sh '.var/app/org.mozilla.firefox/.mozilla/firefox'
assert_contains files/system_files/raptor-app-choice.sh 'Raptor OS low-memory process defaults'
assert_contains files/scripts/raptor-wine/install.sh 'cleanup_idle_wineserver'
assert_contains files/scripts/raptor-wine/install.sh 'umu-run wineboot -k'
assert_contains files/scripts/raptor-wine/install.sh 'pid="${proc##*/}"'
assert_not_contains files/scripts/raptor-wine/install.sh 'WINEPREFIX="$WINEPREFIX" wineserver -k'
assert_contains files/scripts/raptor-cortex/install.sh 'GLib.timeout_add_seconds(15, self._refresh_stats)'

echo "=== Checking ISO and requirements documentation ==="
assert_not_contains .github/workflows/build-iso.yml "jasonn3/build-container-installer"
assert_contains .github/workflows/build-iso.yml "cosign verify --key cosign.pub"
assert_contains .github/workflows/build-iso.yml "mkksiso --ks"
assert_contains README.md "Intel Core i5-8250U"
assert_contains README.md "Vulkan 1.3+"
assert_contains README.md "optimization target under development"
assert_contains changelog.md "v3.0.0 (Major Release"

echo "=== Raptor Tasks installer and embedded Python validation ==="
bash -n files/scripts/raptor-tasks/install.sh
tasks_tmp="$(mktemp --suffix=.py)"
awk "/^cat << 'PYEOF' > \/usr\/bin\/raptor-tasks$/ { inside=1; next } /^PYEOF$/ && inside { exit } inside { print }" files/scripts/raptor-tasks/install.sh > "$tasks_tmp"
test -s "$tasks_tmp"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$tasks_tmp"
grep -Fq 'Gtk.ShortcutController()' "$tasks_tmp"
grep -Fq 'os.fsync(stream.fileno())' "$tasks_tmp"
grep -Fq 'CONFIG_FILE.replace(backup)' "$tasks_tmp"
grep -Fq 'set_placeholder(self.empty_page)' "$tasks_tmp"
grep -Fq 'Search tasks' "$tasks_tmp"
grep -Fq 'self.status_combo' "$tasks_tmp"
grep -Fq 'No matching tasks' "$tasks_tmp"
grep -Fq 'return False' "$tasks_tmp"
grep -Fq 'if self._on_save(saved) is not False:' "$tasks_tmp"
grep -Fq 'stream.write("\n")' "$tasks_tmp"
rm -f "$tasks_tmp"

echo "=== Raptor Wallpaper installer and embedded Python validation ==="
bash -n files/scripts/raptor-wallpaper-manager/install.sh
wallpaper_tmp="$(mktemp --suffix=.py)"
awk "/^cat << 'PYEOF' > \/usr\/bin\/raptor-wallpaper$/ { inside=1; next } /^PYEOF$/ && inside { exit } inside { print }" files/scripts/raptor-wallpaper-manager/install.sh > "$wallpaper_tmp"
test -s "$wallpaper_tmp"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$wallpaper_tmp"
grep -Fq 'os.fsync(stream.fileno())' "$wallpaper_tmp"
grep -Fq 'CONFIG_FILE.replace(backup)' "$wallpaper_tmp"
grep -Fq 'if not os.path.isfile(image_path)' "$wallpaper_tmp"
grep -Fq 'Search wallpapers' "$wallpaper_tmp"
grep -Fq 'self.preview.set_filename' "$wallpaper_tmp"
grep -Fq 'selected_path = self._selected_path' "$wallpaper_tmp"
grep -Fq 'Choose a supported image file' "$wallpaper_tmp"
grep -Fq 'stream.write("\n")' "$wallpaper_tmp"
rm -f "$wallpaper_tmp"

echo "All validations passed."

echo "=== Checking v3.0.0 release integration ==="
assert_contains .github/workflows/build.yml 'REF_NAME: ${{ github.ref_name }}'
assert_contains files/scripts/raptor-cortex/install.sh 'auto|on)'
assert_contains files/scripts/raptor-cortex/install.sh '/sys/class/nvme/nvme*/power/control'
assert_not_contains files/scripts/raptor-cortex/install.sh '_apply_nvme_power      min_power'
assert_not_contains files/scripts/raptor-cortex/install.sh '_apply_nvme_power      max_performance'
assert_contains files/scripts/raptor-gpu-profile/install.sh '_set_intel_gpu_power_mode'
assert_contains files/system_files/99-raptor-wireplumber-alsa.conf 'api.alsa.period-size            = 512'
assert_contains files/system_files/raptor-chat-choice.sh 'Equibop'
assert_contains files/system_files/raptor-chat-choice.sh 'GoofCord'
assert_contains files/system_files/raptor-chat-choice.sh 'flatpak remote-add --user --if-not-exists flathub'
assert_contains files/system_files/raptor-chat-choice.sh 'flatpak install --user -y --noninteractive flathub'
assert_contains files/system_files/raptor-chat-choice.sh 'flatpak info --user'
assert_contains files/system_files/raptor-app-choice.sh 'org.localsend.localsend_app'
assert_contains files/system_files/raptor-app-choice.sh 'it.mijorus.gearlever'
assert_contains files/system_files/raptor-app-choice.sh 'net.nokyan.Resources'
assert_contains recipes/recipe.yml "raptor-bt-name.service"
assert_contains files/scripts/raptor-hardware-fixes/install.sh "system-alias Raptor OS Bluetooth"
assert_contains files/scripts/raptor-hardware-fixes/install.sh "Description=Set a friendly Raptor OS Bluetooth adapter name"
assert_contains files/system_files/raptor-browser-choice.sh 'Zen Browser'
assert_contains files/system_files/raptor-browser-choice.sh 'Floorp'
assert_contains files/system_files/raptor-browser-choice.sh 'Waterfox'
assert_not_contains files/system_files/raptor-browser-choice.sh 'Helium'

echo "=== Checking custom Raptor Shroudly integration ==="
assert_contains .github/workflows/build.yml 'Build and test custom Raptor Shroudly'
assert_contains .github/workflows/build.yml 'cargo build --release --workspace --manifest-path files/scripts/shroudly-raptor/Cargo.toml'
assert_contains .github/workflows/build.yml 'cargo test --workspace --manifest-path files/scripts/shroudly-raptor/Cargo.toml'
assert_contains .github/workflows/build.yml 'files/staging/raptor-shroudly'
assert_contains .github/workflows/build.yml 'Verify both apps inside the published image'
assert_contains .github/workflows/build.yml '/usr/bin/raptor-shroudly'
assert_contains files/scripts/shroudly-raptor/crates/shroudly-raptor/Cargo.toml 'slint = "1.5"'
assert_contains files/scripts/shroudly-raptor/crates/shroudly-raptor/src/gui.rs 'RAPTOR / SHROUDLY'
assert_contains files/scripts/shroudly-raptor/crates/shroudly-raptor/src/gui.rs 'Traffic routing is not enabled in this build.'
assert_contains files/scripts/shroudly-raptor/install.sh '/usr/bin/raptor-shroudly'
assert_contains files/scripts/shroudly-raptor/install.sh 'Name=Raptor Shroudly'
assert_contains files/scripts/shroudly-raptor/install.sh 'raptor-shroudly.svg'
assert_contains files/scripts/shroudly-raptor/README.md 'not the upstream Electron desktop app'
assert_contains files/scripts/shroudly-raptor/README.md 'network routing'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'Raptor Proton'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'standard Wine'

echo "=== Raptor Wine and Proton desktop integration ==="
assert_contains files/scripts/raptor-wine/install.sh 'RAPTOR_PROTON_REGISTER_AFTER'
assert_contains files/scripts/raptor-wine/install.sh 'STEAM_COMPAT_LIBRARY_PATHS'
assert_contains files/scripts/raptor-wine/install.sh 'comm -z -13'
assert_contains files/scripts/raptor-wine/install.sh 'raptor-proton-register-apps'
assert_contains files/scripts/raptor-wine/install.sh 'raptor-proton-launch-installed'
assert_contains files/scripts/raptor-wine/install.sh 'Name=Raptor Proton'
assert_contains files/scripts/raptor-wine/install.sh 'Name=Raptor Wine'
assert_contains files/scripts/raptor-wine/install.sh 'MimeType=application/x-ms-dos-executable;application/vnd.microsoft.portable-executable;application/x-msdownload;application/x-msi;'
assert_contains files/scripts/raptor-wine/install.sh 'UMU_RUNTIME_UPDATE=0'
assert_contains files/scripts/raptor-wine/install.sh 'Categories=Game;'
assert_not_contains files/scripts/raptor-wine/install.sh 'Name=Run with Raptor Proton'
assert_contains files/system_files/zram-generator.conf 'compression-algorithm = lz4'

# Parse the scripts generated by the Wine installer, not just the outer heredoc
# container. This catches syntax errors hidden inside embedded launchers.
wine_tmp="$(mktemp -d)"
awk "/^cat <<'PROTON' > \/usr\/bin\/raptor-wine-proton$/ { inside=1; next } /^PROTON$/ && inside { exit } inside { print }" files/scripts/raptor-wine/install.sh > "$wine_tmp/proton.sh"
awk "/^cat <<'REGISTER' > \/usr\/bin\/raptor-proton-register-apps$/ { inside=1; next } /^REGISTER$/ && inside { exit } inside { print }" files/scripts/raptor-wine/install.sh > "$wine_tmp/register.sh"
awk "/^cat <<'PREFIXLAUNCH' > \/usr\/bin\/raptor-proton-launch-installed$/ { inside=1; next } /^PREFIXLAUNCH$/ && inside { exit } inside { print }" files/scripts/raptor-wine/install.sh > "$wine_tmp/prefix-launch.sh"
awk "/^cat <<'LAUNCH' > \/usr\/lib\/raptor\/launch-windows-app$/ { inside=1; next } /^LAUNCH$/ && inside { exit } inside { print }" files/scripts/raptor-wine/install.sh > "$wine_tmp/launch.sh"
awk "/^cat <<'OPENPROTON' > \/usr\/bin\/raptor-proton-open$/ { inside=1; next } /^OPENPROTON$/ && inside { exit } inside { print }" files/scripts/raptor-wine/install.sh > "$wine_tmp/proton-open.sh"
awk "/^cat <<'MANAGER' > \/usr\/bin\/raptor-proton-manager$/ { inside=1; next } /^MANAGER$/ && inside { exit } inside { print }" files/scripts/raptor-wine/install.sh > "$wine_tmp/proton-manager.sh"
for embedded in "$wine_tmp"/*.sh; do
  test -s "$embedded"
  bash -n "$embedded"
done
awk "/^python3 - .*<<'PY'$/ { inside=1; next } /^PY$/ && inside { exit } inside { print }" files/scripts/raptor-wine/install.sh > "$wine_tmp/desktop-writer.py"
test -s "$wine_tmp/desktop-writer.py"
python3 -m py_compile "$wine_tmp/desktop-writer.py"
rm -rf "$wine_tmp"

assert_contains files/scripts/raptor-music/install.sh 'RAPTOR_MUSIC_PAYLOAD_MISSING'
assert_contains .github/workflows/build.yml 'git add -f -- files/staging'
assert_contains .github/workflows/build.yml 'Verify both apps inside the published image'
assert_contains .github/workflows/build.yml '/usr/bin/raptor-music'
assert_contains .github/workflows/build.yml '/usr/bin/raptor-shroudly'
assert_not_contains .github/workflows/build.yml 'npm ci'
assert_not_contains .github/workflows/build.yml 'files/staging/shroudly-app'
assert_not_contains files/scripts/shroudly-raptor/install.sh 'Name=Shroudly'
assert_not_contains files/scripts/shroudly-raptor/install.sh 'systemctl enable'
echo "All custom Raptor app release contracts passed."


# Wi-Fi watchdog must bound NetworkManager calls and recover stalled activation safely.
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'flock -n 9 || exit 0'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'timeout 25 nmcli -w 20 device connect'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'wifi-busy-count-$dev'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'activation remained stuck'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'automatic driver reload skipped for safety'
assert_not_contains files/scripts/raptor-hardware-fixes/install.sh 'known_in_range && level3 "$dev"'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'nmcli_status() { timeout 5 nmcli'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'count++ < 8'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'timeout 10 modprobe'
assert_not_contains files/scripts/raptor-hardware-fixes/install.sh 'nmcli radio wifi 2>/dev/null'
assert_not_contains files/scripts/raptor-hardware-fixes/install.sh 'nmcli device set "$d" autoconnect yes 2>/dev/null'

echo "=== Checking first-login welcome and hardware telemetry ==="
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'Welcome to Raptor OS Home'
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'bash -n /usr/bin/raptor-welcome.sh'
assert_contains files/system_files/raptor-firstboot.service 'welcome-done'
assert_contains files/system_files/raptor-firstboot.service 'ExecStart=/usr/bin/raptor-welcome.sh'
assert_contains files/scripts/raptor-cortex/install.sh 'title="Graphics Processor"'
assert_contains files/scripts/raptor-cortex/install.sh 'def get_gpu_memory():'
assert_contains files/scripts/raptor-cortex/install.sh 'Telemetry unavailable — check the graphics driver'
assert_contains files/scripts/raptor-cortex/install.sh 'def get_fan_info(hwmon_root="/sys/class/hwmon"):'
assert_contains files/scripts/raptor-cortex/install.sh 'vendor == "0x1002"'
assert_contains files/scripts/raptor-cortex/install.sh 'vendor == "0x8086"'
assert_contains files/scripts/raptor-cortex/install.sh 'NVIDIA GPU {index}'
echo "=== Shell syntax: Raptor Cortex installer ==="
bash -n files/scripts/raptor-cortex/install.sh
echo "=== Python syntax: embedded Raptor Cortex application ==="
cortex_tmp="$(mktemp --suffix=.py)"
awk "/^cat << 'PYEOF' > \\/usr\\/bin\\/raptor-cortex$/ { inside=1; next } /^PYEOF$/ && inside { exit } inside { print }" files/scripts/raptor-cortex/install.sh > "$cortex_tmp"
test -s "$cortex_tmp"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$cortex_tmp"
python3 - "$cortex_tmp" <<'PY'
import ast
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

source = Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(source)
top_imports = {
    alias.name
    for node in tree.body if isinstance(node, ast.Import)
    for alias in node.names
}
assert "re" in top_imports, "Cortex must import re at module scope for GPU discovery"

wanted = {"get_gpu_usage", "get_gpu_summary", "get_fan_info"}
functions = [
    node for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name in wanted
]
assert {node.name for node in functions} == wanted, "GPU/fan telemetry functions missing"

class FakeSubprocess:
    class TimeoutExpired(Exception):
        pass

    @staticmethod
    def run(*_args, **_kwargs):
        return SimpleNamespace(returncode=1, stdout="")

namespace = {"os": os, "re": re, "subprocess": FakeSubprocess}
exec(compile(ast.Module(body=functions, type_ignores=[]), "<cortex-telemetry>", "exec"), namespace)

# Exercise real AMD sysfs parsing, including the regex-dependent card matcher.
with tempfile.TemporaryDirectory() as tmp:
    dev = Path(tmp) / "class/drm/card0/device"
    dev.mkdir(parents=True)
    (dev / "vendor").write_text("0x1002")
    (dev / "gpu_busy_percent").write_text("37")
    (dev / "pp_dpm_sclk").write_text("0: 800Mhz\n1: 1600Mhz *")
    assert namespace["get_gpu_usage"](tmp) == (37, 1600)

# GPU summary must compose model and available metrics without crashing.
namespace["get_gpu_name"] = lambda: "Test GPU"
namespace["get_gpu_usage"] = lambda: (37, 1600)
namespace["get_gpu_memory"] = lambda: "512 / 4096 MB"
summary = namespace["get_gpu_summary"]()
assert "Test GPU" in summary and "Load 37%" in summary and "1600 MHz" in summary

# Exercise both standard RPM telemetry and PWM-only telemetry.
with tempfile.TemporaryDirectory() as tmp:
    hwmon = Path(tmp)
    cpu = hwmon / "hwmon0"
    cpu.mkdir()
    (cpu / "name").write_text("test-ec")
    (cpu / "fan1_input").write_text("2300")
    (cpu / "fan1_label").write_text("CPU Fan")
    gpu = hwmon / "hwmon1"
    gpu.mkdir()
    (gpu / "name").write_text("amdgpu")
    (gpu / "pwm1").write_text("128")
    fans = namespace["get_fan_info"](tmp)
    rendered = " | ".join(f"{name}: {value}" for name, value in fans)
    assert "2300 RPM" in rendered, rendered
    assert "50% PWM duty" in rendered, rendered

print("Cortex GPU and fan telemetry regression tests passed.")
PY
rm -f "$cortex_tmp"


echo "=== Checking Dolphin and archive backends ==="
assert_contains recipes/recipe.yml '      - ark'
assert_contains recipes/recipe.yml '      - 7zip'
assert_contains recipes/recipe.yml '      - unzip'
assert_contains files/system_files/raptor-mimeapps.list 'application/x-zip-compressed=org.kde.ark.desktop'
assert_contains files/system_files/raptor-mimeapps.list 'application/x-cbz=org.kde.ark.desktop'
assert_contains files/system_files/raptor-mimeapps.list 'application/x-zstd=org.kde.ark.desktop'
assert_contains files/system_files/raptor-mimeapps.list 'application/x-cpio=org.kde.ark.desktop'
assert_contains files/system_files/raptor-mimeapps.list 'application/vnd.ms-cab-compressed=org.kde.ark.desktop'

assert_contains files/scripts/raptor-dolphin-stability/install.sh 'command -v ark'
assert_contains files/scripts/raptor-dolphin-stability/install.sh 'command -v unzip'
assert_contains files/scripts/raptor-dolphin-stability/install.sh 'set -euo pipefail'
echo "=== Shell syntax: archive stability installer ==="
bash -n files/scripts/raptor-dolphin-stability/install.sh
assert_contains files/scripts/raptor-dolphin-stability/install.sh 'raptor-ark-extract.desktop'
assert_contains files/scripts/raptor-dolphin-stability/install.sh 'ark --batch --autodestination --autosubfolder %F'
assert_contains files/scripts/raptor-dolphin-stability/install.sh 'ark --batch --dialog %F'
assert_contains files/scripts/raptor-dolphin-stability/install.sh 'ark --add %F'
assert_contains files/scripts/raptor-dolphin-stability/install.sh 'chmod 0755 "$SERVICE_MENU_DIR/raptor-ark-create.desktop"'


echo "=== Checking Cortex multi-page control center ==="
assert_contains files/scripts/raptor-cortex/install.sh 'Adw.ViewStack()'
assert_contains files/scripts/raptor-cortex/install.sh 'add_page("overview", "Overview")'
assert_contains files/scripts/raptor-cortex/install.sh 'add_page("graphics", "Graphics")'
assert_contains files/scripts/raptor-cortex/install.sh 'title="GPU telemetry"'
assert_contains files/scripts/raptor-cortex/install.sh 'graphics_content.append(gpu_telemetry_group)'
assert_contains files/scripts/raptor-cortex/install.sh 'gpu_telemetry_group.add(self.gpu_info_row)'

assert_contains files/scripts/raptor-cortex/install.sh 'add_page("games", "Games")'
assert_contains files/scripts/raptor-cortex/install.sh 'add_page("optimize", "Optimize")'
assert_contains files/scripts/raptor-cortex/install.sh 'add_page("settings", "Settings")'
assert_contains files/scripts/raptor-cortex/install.sh 'GLib.timeout_add_seconds(15, self._refresh_stats)'

echo "=== Checking memory compression defaults ==="
assert_contains files/system_files/zram-generator.conf 'zram-size = min(ram, 8192)'
assert_contains files/system_files/zram-generator.conf 'compression-algorithm = lz4'
assert_not_contains files/system_files/zram-generator.conf 'compression-algorithm = zstd'


echo "=== Raptor Update Manager rollback and lock-screen validation ==="
bash -n files/scripts/raptor-update/install.sh
assert_contains files/scripts/raptor-update/install.sh 'rpm-ostree upgrade --download-only --unchanged-exit-77'
assert_contains files/scripts/raptor-update/install.sh 'CHECK_TIMEOUT         = 1860'
assert_contains files/scripts/raptor-update/install.sh 'Update image resolved and downloaded; no deployment was created.'
assert_not_contains files/scripts/raptor-update/install.sh 'timeout "${ATTEMPT_TIMEOUT}" rpm-ostree upgrade --check'
# Exercise both authoritative outcomes with a fake rpm-ostree binary: exit 77
# means no update; exit 0 means the image was resolved/downloaded, without a
# deployment. This protects the check path from regressing to --check-only.
check_tmp="$(mktemp --suffix=.sh)"
awk "/^cat << 'EOF' > \/usr\/lib\/raptor\/check-helper$/ { inside=1; next } /^EOF$/ && inside { exit } inside { print }" files/scripts/raptor-update/install.sh > "$check_tmp"
test -s "$check_tmp"
bash -n "$check_tmp"
check_test_dir="$(mktemp -d)"
mkdir -p "$check_test_dir/bin"
cat > "$check_test_dir/bin/rpm-ostree" <<'RPMOSTREE'
#!/bin/bash
printf '%s\\n' "$*" >> "$RAPTOR_TEST_CALLS"
echo "${RAPTOR_TEST_RPM_OUTPUT:-}"
exit "${RAPTOR_TEST_RPM_RC:-0}"
RPMOSTREE
chmod +x "$check_test_dir/bin/rpm-ostree"
export PATH="$check_test_dir/bin:$PATH"
export RAPTOR_TEST_CALLS="$check_test_dir/calls"
export RAPTOR_CHECK_MAX_ATTEMPTS=1
export RAPTOR_CHECK_ATTEMPT_TIMEOUT=3
export RAPTOR_TEST_RPM_RC=77
bash "$check_tmp" > "$check_test_dir/no-update.log"
grep -Fq 'No upgrade available.' "$check_test_dir/no-update.log"
if grep -Fq 'AvailableUpdate:' "$check_test_dir/no-update.log"; then
  echo "Update checker marked exit 77 as an available update" >&2
  exit 1
fi
export RAPTOR_TEST_RPM_RC=0
bash "$check_tmp" > "$check_test_dir/update.log"
grep -Fq 'AvailableUpdate:' "$check_test_dir/update.log"
grep -Fq 'upgrade --download-only --unchanged-exit-77' "$RAPTOR_TEST_CALLS"
unset RAPTOR_TEST_CALLS RAPTOR_CHECK_MAX_ATTEMPTS RAPTOR_CHECK_ATTEMPT_TIMEOUT RAPTOR_TEST_RPM_RC
rm -f "$check_tmp"
rm -rf "$check_test_dir"
echo "OCI-aware Update Manager detection tests passed."
update_tmp="$(mktemp --suffix=.py)"
awk "/^cat << 'PYEOF' > \/usr\/bin\/raptor-update$/ { inside=1; next } /^PYEOF$/ && inside { exit } inside { print }" files/scripts/raptor-update/install.sh > "$update_tmp"
test -s "$update_tmp"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$update_tmp"
grep -Fq 'ROLLBACK_HELPER       = "/usr/lib/raptor/rollback-helper"' "$update_tmp"
grep -Fq 'def on_rollback_clicked(self, _btn):' "$update_tmp"
grep -Fq 'def _run_rollback(self):' "$update_tmp"
grep -Fq 'GLib.idle_add(self.rollback_btn.set_sensitive, available)' "$update_tmp"
grep -Fq 'no automatic restart was performed.' "$update_tmp"
rm -f "$update_tmp"
assert_contains files/scripts/raptor-update/install.sh 'cat << '\''EOF'\'' > /usr/lib/raptor/rollback-helper'
assert_contains files/scripts/raptor-update/install.sh 'rpm-ostree rollback'
assert_contains files/scripts/raptor-update/install.sh 'ROLLBACK_ACTION'
assert_contains files/scripts/raptor-update/install.sh 'io.github.cerberus9dev.raptorupdate.rollback'
assert_contains files/scripts/raptor-update/install.sh '/usr/lib/raptor/rollback-helper'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh 'def apply_lockscreen_wallpaper(image_path):'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh 'kwriteconfig6'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh 'WallpaperPlugin'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh 'PreviewImage'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh 'Apply to Lock Screen'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh '/usr/bin/raptor-wallpaper-launch'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh 'wallpaper-$stamp-$.log'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh 'Exec=/usr/bin/raptor-wallpaper-launch'
assert_contains files/scripts/raptor-wallpaper-manager/install.sh 'import shutil'
echo "Raptor recovery and lock-screen contracts passed."

echo "=== Checking GPU vendor-safe defaults ==="
assert_contains files/scripts/raptor-gpu-profile/install.sh 'NVAPI_VAR="PROTON_ENABLE_NVAPI=1"'
assert_not_contains files/scripts/raptor-gpu-profile/install.sh 'AMD_VULKAN_ICD=RADV'
assert_not_contains files/scripts/raptor-gpu-profile/install.sh 'MESA_LOADER_DRIVER_OVERRIDE=iris'
assert_not_contains files/scripts/raptor-gpu-profile/install.sh 'VKD3D_CONFIG='
assert_not_contains files/scripts/raptor-gpu-profile/install.sh 'VKD3D_FEATURE_LEVEL='
assert_not_contains files/scripts/raptor-gpu-profile/install.sh 'RADV_PERFTEST=gpl'
assert_not_contains files/scripts/raptor-gpu-profile/install.sh '__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1'
assert_not_contains files/scripts/raptor-gpu-profile/install.sh '__GL_THREADED_OPTIMIZATIONS='
echo "GPU vendor-safe defaults passed."

echo "=== Checking CI image tag and generated app payload staging ==="
assert_contains .github/workflows/build.yml 'IMAGE_VERSION_SUFFIX="${IMAGE_VERSION##*-}"'
assert_contains .github/workflows/build.yml 'IMAGE_TAG="pr-$PR_NUMBER-$IMAGE_VERSION_SUFFIX"'
assert_contains .github/workflows/build.yml 'IMAGE_TAG="${GITHUB_SHA:0:7}-$IMAGE_VERSION_SUFFIX"'
assert_contains .github/workflows/build.yml 'BlueBuild publishes the short commit-SHA tag for push,'
assert_not_contains .github/workflows/build.yml 'IMAGE_TAG="${REF_TAG}-$IMAGE_VERSION_SUFFIX"'
assert_contains files/scripts/raptor-music/install.sh 'if [[ ! -x "$SRC_BIN" && -x "/tmp/files/staging/raptor-music" ]]; then'
assert_contains files/scripts/shroudly-raptor/install.sh 'if [[ ! -x "$STAGED_BIN" && -x "/tmp/files/staging/raptor-shroudly" ]]; then'
assert_contains files/scripts/raptor-music/install.sh 'STAGE_DIR="/tmp/files/staging"'
assert_contains files/scripts/shroudly-raptor/install.sh 'STAGED_BIN="/tmp/files/staging/raptor-shroudly"'
echo "Image tagging and payload staging contracts passed."

echo "=== Checking boot-time GPU detection safety ==="
gpu_tmp="$(mktemp --suffix=.sh)"
awk "/^cat << 'DETECT' > \/usr\/lib\/raptor\/gpu-detect.sh$/ { inside=1; next } /^DETECT$/ && inside { exit } inside { print }" files/scripts/raptor-gpu-profile/install.sh > "$gpu_tmp"
test -s "$gpu_tmp"
bash -n "$gpu_tmp"
grep -Fq 'GPU_PCI_INFO="$(timeout 3s lspci -nn' "$gpu_tmp"
grep -Fq 'timeout 3s lspci -v' "$gpu_tmp"
grep -Fq 'timeout 3s nvidia-smi' "$gpu_tmp"
grep -Fq 'timeout 2s loginctl list-users' "$gpu_tmp"
if grep -Fq 'sysctl --system' "$gpu_tmp"; then
  echo "GPU profile must not re-run the global sysctl loader during boot" >&2
  exit 1
fi
rm -f "$gpu_tmp"
echo "Boot-time GPU detection contracts passed."

echo "=== Checking embedded Raptor Cortex Python ==="
cortex_tmp="$(mktemp --suffix=.py)"
awk "/^cat << 'PYEOF' > \/usr\/bin\/raptor-cortex$/ { inside=1; next } /^PYEOF$/ && inside { exit } inside { print }" files/scripts/raptor-cortex/install.sh > "$cortex_tmp"
test -s "$cortex_tmp"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$cortex_tmp"
rm -f "$cortex_tmp"

echo "=== Checking boot ordering for known latency traps ==="
if grep -R -n 'systemd-udev-settle\.service' recipes files/system_files files/scripts; then
  echo "Do not add a global udev-settle dependency to the boot path" >&2
  exit 1
fi
assert_contains recipes/recipe.yml "- power-profiles-daemon.service"
assert_not_contains recipes/recipe.yml 'raptor-powerprofile.service'
assert_not_contains recipes/recipe.yml 'raptor-ensure-services.service'
test ! -e files/system_files/raptor-powerprofile.service
test ! -e files/system_files/raptor-ensure-services.service
assert_contains files/scripts/raptor-gpu-profile/install.sh 'GPU_PCI_INFO="$(timeout 3s lspci -nn'
echo "Boot latency regression checks passed."

echo "=== Checking user-controlled Wi-Fi power management ==="
assert_not_contains files/system_files/91-raptor-network.conf 'wifi.powersave=2'
assert_not_contains files/system_files/91-raptor-network.conf 'wifi.scan-rand-mac-address=no'
assert_contains files/scripts/raptor-cortex/install.sh 'wifi-powersave)'
assert_contains files/scripts/raptor-cortex/install.sh 'Disable Wi-Fi power saving'
assert_contains files/scripts/raptor-cortex/install.sh '91-raptor-wifi-powersave.conf'
assert_contains files/scripts/raptor-cortex/install.sh 'NetworkManager default'
wifi_helper_tmp="$(mktemp --suffix=.sh)"
awk "/^cat << 'EOF' > \/usr\/lib\/raptor\/cortex-helper$/ { inside=1; next } /^EOF$/ && inside { exit } inside { print }" files/scripts/raptor-cortex/install.sh > "$wifi_helper_tmp"
test -s "$wifi_helper_tmp"
bash -n "$wifi_helper_tmp"
grep -Fq "printf '[connection]" "$wifi_helper_tmp"
wifi_test_dir="$(mktemp -d)"
mkdir -p "$wifi_test_dir/bin"
cat > "$wifi_test_dir/bin/nmcli" <<'NMCLI'
#!/bin/sh
exit "${RAPTOR_TEST_NMCLI_EXIT:-0}"
NMCLI
chmod +x "$wifi_test_dir/bin/nmcli"
export PATH="$wifi_test_dir/bin:$PATH"
export RAPTOR_NM_CONF_DIR="$wifi_test_dir/conf"
export RAPTOR_TEST_NMCLI_EXIT=0
bash "$wifi_helper_tmp" wifi-powersave disable
wifi_conf="$RAPTOR_NM_CONF_DIR/91-raptor-wifi-powersave.conf"
grep -Fxq '[connection]' "$wifi_conf"
grep -Fxq 'wifi.powersave=2' "$wifi_conf"
bash "$wifi_helper_tmp" wifi-powersave default
test ! -e "$wifi_conf"
printf '[connection]\nwifi.powersave=3\n' > "$wifi_conf"
export RAPTOR_TEST_NMCLI_EXIT=1
if bash "$wifi_helper_tmp" wifi-powersave disable; then
  echo "Wi-Fi helper unexpectedly succeeded when NetworkManager reload failed" >&2
  exit 1
fi
grep -Fxq 'wifi.powersave=3' "$wifi_conf"
unset RAPTOR_NM_CONF_DIR RAPTOR_TEST_NMCLI_EXIT
rm -f "$wifi_helper_tmp"
rm -rf "$wifi_test_dir"
echo "Wi-Fi power-management contracts passed."

echo "=== Checking conservative gaming defaults ==="
assert_not_contains files/scripts/raptor-gaming/install.sh '@bEnableShaderPreCaching'
assert_not_contains files/scripts/raptor-gaming/install.sh '@nClientDownloadEnableHTTP2PlatformLinux'
assert_not_contains files/scripts/raptor-gaming/install.sh '@fDownloadRateImprovementToAddAnotherConnection'
assert_not_contains files/scripts/raptor-gaming/install.sh '@cMaxFileSystemWriteBufferSizeBytes'
assert_not_contains files/scripts/raptor-gaming/install.sh 'apply_gpu_optimisations=accept-responsibility'
assert_not_contains files/scripts/raptor-gaming/install.sh 'amd_performance_level=high'
assert_not_contains files/scripts/raptor-gaming/install.sh 'nv_powermizer_mode=1'
assert_not_contains files/scripts/raptor-gaming/install.sh 'ATTR{power/autosuspend}="-1"'
assert_not_contains files/scripts/raptor-gaming/install.sh 'ATTR{power/control}="on"'
assert_contains files/scripts/raptor-gaming/install.sh 'KERNEL=="uinput"'
assert_contains files/scripts/raptor-gaming/install.sh 'ATTRS{name}=="Xbox*"'
echo "Conservative gaming defaults passed."

echo "=== Checking suspend/resume service ownership ==="
assert_not_contains recipes/recipe.yml 'raptor-resume-trigger.service'
assert_not_contains recipes/recipe.yml 'raptor-lid-open-fix.service'
assert_not_contains recipes/recipe.yml 'raptor-cpugovernor.service'
assert_contains files/scripts/raptor-hardware-fixes/install.sh "cat << 'EOF' > /usr/lib/systemd/system-sleep/raptor-resume"
assert_contains files/scripts/raptor-hardware-fixes/install.sh 'post) rebind_touchpads'
test ! -e files/system_files/raptor-resume-trigger.service
test ! -e files/system_files/raptor-lid-open-fix.service
test ! -e files/system_files/raptor-cpugovernor.service
echo "Suspend/resume ownership checks passed."
