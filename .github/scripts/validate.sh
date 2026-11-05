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
assert_contains files/system_files/zram-generator.conf "compression-algorithm = lz4"
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
assert_contains .github/workflows/build.yml "steps.one_time_apps.outputs.include == 'true' || github.event_name == 'pull_request'"
assert_contains .github/workflows/build.yml 'cargo build --release --workspace --manifest-path files/scripts/raptor-music/Cargo.toml'
assert_contains .github/workflows/build.yml 'cargo test --workspace --manifest-path files/scripts/raptor-music/Cargo.toml'
assert_contains .github/workflows/build.yml 'PR validation only: built Raptor Music without staging it into the image.'
assert_not_contains files/scripts/raptor-update/install.sh "for line in user_proc.stdout"
assert_not_contains files/scripts/raptor-update/install.sh "for line in fp_proc.stdout"

echo "=== Checking ISO and requirements documentation ==="
assert_not_contains .github/workflows/build-iso.yml "jasonn3/build-container-installer"
assert_contains .github/workflows/build-iso.yml "cosign verify --key cosign.pub"
assert_contains .github/workflows/build-iso.yml "mkksiso --ks"
assert_contains README.md "Intel Core i5-8250U"
assert_contains README.md "Vulkan 1.3+"
assert_contains README.md "optimization target under development"
assert_contains changelog.md "v3.0.0 (Major Release — planned)"

echo "All validations passed."

echo "=== Checking v3.0.0 release integration ==="
assert_contains .github/workflows/build.yml 'REF_NAME: ${{ github.ref_name }}'
assert_contains .github/workflows/build.yml 'raptor-one-time-apps-consumed'
assert_contains .github/one-time-apps-v3.0.0 'first successful'
assert_contains files/scripts/raptor-cortex/install.sh 'auto|on)'
assert_contains files/scripts/raptor-cortex/install.sh '/sys/class/nvme/nvme*/power/control'
assert_not_contains files/scripts/raptor-cortex/install.sh '_apply_nvme_power      min_power'
assert_not_contains files/scripts/raptor-cortex/install.sh '_apply_nvme_power      max_performance'
assert_contains files/scripts/raptor-gpu-profile/install.sh '_set_intel_gpu_power_mode'
assert_contains files/system_files/99-raptor-wireplumber-alsa.conf 'api.alsa.period-size            = 512'
assert_contains files/system_files/raptor-chat-choice.sh 'Equibop'
assert_contains files/system_files/raptor-chat-choice.sh 'GoofCord'
assert_contains files/system_files/raptor-browser-choice.sh 'Zen Browser'
assert_contains files/system_files/raptor-browser-choice.sh 'Floorp'
assert_contains files/system_files/raptor-browser-choice.sh 'Waterfox'
assert_not_contains files/system_files/raptor-browser-choice.sh 'Helium'

echo "=== Checking Shroudly exclusion from v3.0.0 ==="
assert_not_contains recipes/recipe.yml 'shroudly-raptor/install.sh'
assert_not_contains .github/workflows/build.yml 'Build Shroudly Raptor'
assert_contains README.md 'Not included in v3.0.0'
assert_contains changelog.md 'not built, fetched, or installed'
echo "All v3.0.0 release contracts passed."
