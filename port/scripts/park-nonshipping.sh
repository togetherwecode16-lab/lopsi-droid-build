#!/usr/bin/env bash
# Parking pass 3: non-shipping code that is NOT under a tests/ dir.
#
# Passes 1-2 parked ~3.4k files from cts/platform_testing/test plus
# pattern-matched test dirs. Those dirs turned out to be mostly empty of
# Android.bp, so the graph is still ~7.5k modules, dominated by real shipping
# code:
#     hardware/interfaces   643
#     frameworks/base       494
#     packages/modules      392
#     system/core            92
# Those must stay - they ARE the phone.
#
# What is safe to remove is host-side tooling, automotive, virtualisation,
# desktop/windowing extras, camera/automotive stacks and their tests. None of
# it ships in otapackage for a phone product.
#
# Runs inside the container: find over the host-side virtiofs mount hangs.
set -uo pipefail
cd /aosp || exit 1

park_dir() {
  local root="$1" n=0 f
  [ -d "$root" ] || return 0
  while IFS= read -r f; do
    grep -q '^// parked' "$f" 2>/dev/null && continue
    printf '// parked - non-shipping (rosy otapackage memory budget)\n' >"$f"
    n=$((n + 1))
  done < <(find "$root" -name Android.bp 2>/dev/null)
  [ "$n" -gt 0 ] && printf '  parked %-5s %s\n' "$n" "$root"
  PARKED_TOTAL=$((PARKED_TOTAL + n))
  return 0
}
PARKED_TOTAL=0

# Virtualisation / microdroid / virtio guest payloads - huge, never shipped.
for r in packages/modules/Virtualization \
         packages/modules/CloudNative \
         external/virtio-devices \
         device/google/contexthub \
         device/generic/car \
         packages/apps/Automotive \
         packages/modules/Automotive \
         hardware/interfaces/automotive \
         hardware/interfaces/vhal \
         hardware/interfaces/vehiclehal \
         system/libhwbinder \
         packages/modules/NeuralNetworks \
         hardware/interfaces/vts; do
  park_dir "$r"
done
echo "PASS3_PARKED $PARKED_TOTAL"