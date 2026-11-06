#!/usr/bin/env bash
# Count remaining (unparked) Android.bp files per top-level tree.
# Runs in the container: a find over the host-side virtiofs mount hangs.
set -uo pipefail
cd /aosp || exit 1
for d in frameworks packages system hardware external device art libcore \
         bootable bionic tools development sdk kernel test; do
  [ -d "$d" ] || continue
  n=$(grep -rl 'name:' "$d" --include=Android.bp 2>/dev/null | wc -l | tr -d ' ')
  printf '%6s  %s\n' "$n" "$d"
done | sort -rn
echo "---"
echo "total active: $(grep -rl 'name:' . --include=Android.bp --exclude-dir=out --exclude-dir=.repo --exclude-dir=prebuilts 2>/dev/null | wc -l | tr -d ' ')"