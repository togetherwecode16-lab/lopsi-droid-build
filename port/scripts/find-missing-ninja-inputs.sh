#!/usr/bin/env bash
# List inputs of a ninja target that don't exist on disk and have no rule producing them.
# Run inside the container: find-missing-ninja-inputs.sh [target]
set -euo pipefail
TARGET="${1:-otapackage}"
cd /aosp
NINJA=prebuilts/build-tools/linux-arm64/bin/ninja
F=out/combined-dot_rosy.ninja
W=/tmp/missing-inputs
mkdir -p "$W"
"$NINJA" -f "$F" -t inputs "$TARGET" | LC_ALL=C sort -u > "$W/inputs.txt"
echo "inputs: $(wc -l < "$W/inputs.txt")"
"$NINJA" -f "$F" -t targets all | sed 's/: [^:]*$//' | LC_ALL=C sort -u > "$W/outputs.txt"
echo "outputs: $(wc -l < "$W/outputs.txt")"
LC_ALL=C comm -23 "$W/inputs.txt" "$W/outputs.txt" > "$W/sources.txt"
echo "sources: $(wc -l < "$W/sources.txt")"
while IFS= read -r p; do [ -e "$p" ] || echo "$p"; done < "$W/sources.txt" > "$W/missing.txt"
echo "missing: $(wc -l < "$W/missing.txt")"
