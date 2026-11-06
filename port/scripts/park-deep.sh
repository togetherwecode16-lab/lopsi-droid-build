#!/usr/bin/env bash
# Deep parking pass: cut the soong graph down to roughly a few thousand modules
# by parking every Android.bp that is test-, benchmark-, fuzz-, vts- or
# hosttool-only. soong analysis on this 16GB host cannot hold the full graph.
#
# The stub pass (park-and-stub.sh) must run AFTER this so every name that
# disappears here still resolves for its dependents.
#
# Runs inside the container - a find over the host-side virtiofs mount hangs.
set -uo pipefail
cd /aosp || exit 1

park() {  # park <file...>
  local n=0 f
  for f in "$@"; do
    [ -f "$f" ] || continue
    grep -q '^// parked' "$f" 2>/dev/null && continue
    printf '// parked - non-shipping (rosy otapackage memory budget)\n' >"$f"
    n=$((n + 1))
  done
  echo "$n"
}

# --- 1. whole subtrees that are never shipped ------------------------------
# CTS/ITS/VTS, tradefed harnesses, automotive test rigs, fuzz corpora.
# NOTE: glob patterns are expanded by the shell running this script (inside
# the VM). They must NOT be quoted, or they arrive here literally.
total=0
park_root() {
  local root="$1" n=0
  [ -d "$root" ] || return 0
  mapfile -t files < <(find "$root" -name Android.bp 2>/dev/null)
  [ "${#files[@]}" -eq 0 ] && return 0
  n=$(park "${files[@]}")
  total=$((total + n))
  [ "$n" -gt 0 ] && echo "  parked $n in $root"
  return 0
}

for root in cts platform_testing test art/test art/tests bootable/*/tests \
            external/*/tests external/*/test external/*/*/tests \
            hardware/interfaces/*/vts hardware/interfaces/*/test \
            hardware/interfaces/tests hardware/*/tests \
            packages/modules/Automotive packages/apps/*/tests \
            packages/modules/*/tests packages/modules/*/test \
            frameworks/*/tests frameworks/*/*/tests \
            system/*/tests system/*/test system/*/*/tests \
            development/tests device/*/*/tests device/*/*/test \
            tools/*/tests; do
  park_root "$root"
done
echo "SUBTREE_PARKED $total"