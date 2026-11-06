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
assert_contains files/system_files/raptor-powerprofile.service "ExecStart=/usr/bin/powerprofilesctl get"
assert_not_contains files/system_files/raptor-powerprofile.service "powerprofilesctl set balanced"
assert_contains recipes/recipe.yml "- power-profiles-daemon.service"
assert_contains files/scripts/raptor-cortex/install.sh "def _sync_external_power_mode"
assert_contains files/scripts/raptor-cortex/install.sh "def _do_one_click_boost"
assert_contains files/scripts/raptor-cortex/install.sh "ACTUAL_PROFILE"
assert_contains files/scripts/raptor-cortex/install.sh '"drkonqi"'

echo "=== Checking memory, audio and browser contracts ==="
# ZRAM defaults are validated below against the current zstd configuration.
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
assert_contains files/scripts/raptor-wine/install.sh "exec umu-run"
assert_contains files/scripts/raptor-wine/install.sh 'target="$1"'
assert_not_contains files/scripts/raptor-wine/install.sh 'RAPTOR_WINE_ERROR: UMU is not installed'
assert_contains files/scripts/raptor-wine/install.sh 'MSI installers should be run with standard Wine'
assert_not_contains files/scripts/raptor-wine/install.sh 'exec umu-run wine msiexec'
assert_contains files/scripts/raptor-wine/install.sh 'shift'
assert_contains files/scripts/raptor-wine/install.sh 'Usage: raptor-wine-proton program.exe'
assert_contains files/scripts/raptor-wine/install.sh "Exec=raptor-wine %f"
assert_contains files/scripts/raptor-wine/install.sh "Exec=raptor-wine-proton %f"
assert_not_contains files/scripts/raptor-wine/install.sh "zenity"
assert_not_contains files/scripts/raptor-wine/install.sh "wineboot -u"
assert_not_contains files/scripts/raptor-wine/install.sh "winetricks --unattended"
assert_contains files/system_files/raptor-mimeapps.list "application/x-ms-dos-executable=raptor-wine.desktop"
assert_contains files/system_files/raptor-mimeapps.list "application/x-msi=raptor-wine.desktop"
assert_not_contains files/system_files/10-raptor-wine.conf "WINEESYNC=1"
assert_not_contains files/system_files/10-raptor-wine.conf "WINEFSYNC=1"

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
assert_contains files/scripts/raptor-update/install.sh "CHECK_TIMEOUT         = 660"
assert_contains files/scripts/raptor-update/install.sh "start_new_session=True"
assert_contains files/scripts/raptor-update/install.sh "os.killpg"
assert_contains files/scripts/raptor-update/install.sh "timeout=3 * 60 * 60"
assert_contains files/scripts/raptor-update/install.sh "timeout=900"
assert_contains files/scripts/raptor-update/install.sh 'rpm-ostree upgrade 2>&1 | tee "$out"'
assert_contains files/scripts/raptor-update/install.sh "_stop_process_group(helper)"
assert_contains .github/workflows/build.yml 'cargo build --release --workspace --manifest-path files/scripts/raptor-music/Cargo.toml'
assert_contains .github/workflows/build.yml 'cargo test --workspace --manifest-path files/scripts/raptor-music/Cargo.toml'
assert_contains .github/workflows/build.yml 'test -x files/staging/raptor-music'
assert_contains .github/workflows/build.yml 'test -x files/staging/shroudly-app/shroudly'
assert_contains .github/workflows/build.yml 'Verify both apps inside the published image'
assert_not_contains .github/workflows/build.yml 'PR validation only: built Raptor Music without staging it into the image.'
assert_not_contains files/scripts/raptor-update/install.sh "for line in user_proc.stdout"
assert_not_contains files/scripts/raptor-update/install.sh "for line in fp_proc.stdout"

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
grep -Fq 'set_placeholder(empty)' "$tasks_tmp"
grep -Fq 'Search tasks' "$tasks_tmp"
grep -Fq 'self.status_combo' "$tasks_tmp"
grep -Fq 'stream.write("\\n")' "$tasks_tmp"
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
grep -Fq 'stream.write("\\n")' "$wallpaper_tmp"
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

echo "=== Checking original upstream Shroudly v3.0.0 integration ==="
assert_contains .github/workflows/build.yml 'git submodule update --init --depth 1 files/scripts/shroudly-raptor/upstream'
assert_contains .github/workflows/build.yml 'npm ci'
assert_contains .github/workflows/build.yml 'npm run test:core'
assert_contains .github/workflows/build.yml 'npm run verify'
assert_contains .github/workflows/build.yml 'npm run build:core:advanced'
assert_contains .github/workflows/build.yml 'npx electron-builder --linux dir --publish never'
assert_contains .github/workflows/build.yml 'test -x dist/linux-unpacked/shroudly'
assert_contains .github/workflows/build.yml '../../../staging/shroudly-app'
assert_contains recipes/recipe.yml 'shroudly-raptor/install.sh'
assert_contains recipes/recipe.yml 'mesa-libgbm'
assert_contains files/scripts/shroudly-raptor/install.sh '/opt/Shroudly'
assert_contains files/scripts/shroudly-raptor/install.sh 'shroudly-core-adv'
assert_contains files/scripts/shroudly-raptor/install.sh 'me.codeshare.shroudly.policy'
assert_contains files/scripts/shroudly-raptor/install.sh 'SHROUDLY_READY'
assert_contains files/scripts/shroudly-raptor/install.sh 'no complete Shroudly payload in this image build'
assert_contains files/scripts/raptor-music/install.sh 'no Raptor Music payload in this image build'
assert_contains files/scripts/raptor-music/install.sh 'RAPTOR_MUSIC_PAYLOAD_MISSING'
assert_contains .github/workflows/build.yml 'git add -f -- files/staging'
assert_contains .github/workflows/build.yml 'Verify both apps inside the published image'
assert_contains .github/workflows/build.yml 'docker run --rm --entrypoint /bin/bash'
assert_contains .github/workflows/build.yml '/usr/bin/raptor-music'
assert_contains .github/workflows/build.yml '/usr/bin/shroudly'
assert_not_contains files/scripts/shroudly-raptor/install.sh 'Terminal=true'
assert_not_contains files/scripts/shroudly-raptor/install.sh 'systemctl enable'
echo "All v3.0.0 release contracts passed."


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
assert_contains files/scripts/raptor-cortex/install.sh 'def get_fan_info():'
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
assert_contains files/scripts/raptor-cortex/install.sh 'GLib.timeout_add_seconds(8, self._refresh_stats)'

echo "=== Checking memory compression defaults ==="
assert_contains files/system_files/zram-generator.conf 'zram-size = min(ram, 8192)'
assert_contains files/system_files/zram-generator.conf 'compression-algorithm = zstd'
assert_not_contains files/system_files/zram-generator.conf 'compression-algorithm = lz4'
