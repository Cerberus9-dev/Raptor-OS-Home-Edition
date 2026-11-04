#!/bin/bash
set -euo pipefail

echo "=== Validating installer scripts ==="

# Check all installer scripts exist and have valid syntax
for script in files/scripts/raptor-*.sh; do
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
        if [[ "$line" =~ -[[:space:]]*raptor- ]]; then
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

echo "All validations passed."
