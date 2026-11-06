#!/usr/bin/env bash
# Park every Android.bp under the given roots so soong stops parsing them.
# Run inside the container: the host-side virtiofs walk is far too slow.
set -uo pipefail
total=0
for root in "$@"; do
  [ -d "/aosp/$root" ] || { echo "SKIP $root (missing)"; continue; }
  c=0
  while IFS= read -r f; do
    if grep -q '^// parked' "$f" 2>/dev/null; then continue; fi
    printf '// parked - test tree (rosy otapackage memory budget)\n' >"$f"
    c=$((c + 1))
  done < <(find "/aosp/$root" -name Android.bp 2>/dev/null)
  echo "PARKED_TREE $root ($c files)"
  total=$((total + c))
done
echo "PARKED_TOTAL $total"