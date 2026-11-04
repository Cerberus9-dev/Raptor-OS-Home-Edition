#!/bin/bash
set -euo pipefail

curl --retry 3 --retry-delay 2 --fail --location \
    --output /etc/yum.repos.d/brave-browser.repo \
    https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
