#!/usr/bin/env bash
# Build DotOS A17 (dot_rosy) and package a LopsiDot Updates flashable zip.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
AOSP="${AOSP_DIR:-$PORT/aosp}"
OUT_DIR="$PORT/out"
BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"
mkdir -p "$OUT_DIR" "$PORT/logs"

if [ ! -f "$AOSP/build/envsetup.sh" ]; then
  echo "AOSP not synced. Run: $PORT/scripts/sync-aosp17.sh"
  exit 1
fi

# Refresh vendor/device overlays
rm -rf "$AOSP/vendor/dot"
cp -a "$PORT/vendor_dot" "$AOSP/vendor/dot"
rsync -a --delete --exclude .git "$PORT/trees/device_xiaomi_rosy/" "$AOSP/device/xiaomi/rosy/"

cd "$AOSP"
# Modern AOSP lunch: aosp_<device> style; our product is dot_rosy
set +u
source build/envsetup.sh
# Try both lunch forms (AOSP 17 vs older)
lunch dot_rosy-trunk_staging-userdebug || lunch dot_rosy-bp2a-userdebug || lunch aosp_arm64-eng
set -u

echo "==> building (this takes hours on first run)"
echo "==> using $BUILD_JOBS build jobs"
m -j"$BUILD_JOBS" bacon 2>&1 | tee "$PORT/logs/build-dot-a17.log" \
  || m -j"$BUILD_JOBS" otapackage 2>&1 | tee -a "$PORT/logs/build-dot-a17.log"

"$PORT/scripts/package-lopsidot-ota.sh"
