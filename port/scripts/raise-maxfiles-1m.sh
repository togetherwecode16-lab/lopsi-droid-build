#!/usr/bin/env bash
# Raise Mac open-file limit to 1M (needed for AOSP soong / high -j)
set -euo pipefail
sudo sysctl -w kern.maxfilesperproc=1048576
sudo sysctl -w kern.maxfiles=1048576
sysctl kern.maxfilesperproc kern.maxfiles
echo "OK — 1M set. Rebuild will use -j=\$(nproc) automatically."
