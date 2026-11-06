#!/usr/bin/env bash
# Init AOSP Android 17 + wire DotOS/rosy port trees for LopsiDot Updates builds.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
AOSP="${AOSP_DIR:-$PORT/aosp}"
export PATH="$HOME/bin:$PATH"

mkdir -p "$AOSP"
cd "$AOSP"

if [ ! -d .repo ]; then
  echo "==> repo init android-17.0.0_r1"
  repo init -u https://android.googlesource.com/platform/manifest -b android-17.0.0_r1 --depth=1 --git-lfs
fi

mkdir -p .repo/local_manifests
cp -f "$PORT/manifests/lopsidot_rosy.xml" .repo/local_manifests/lopsidot_rosy.xml

echo "==> shallow sync (long). Logs: $PORT/logs/repo-sync.log"
repo sync -c -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" --force-sync --no-tags --no-clone-bundle \
  2>&1 | tee "$PORT/logs/repo-sync.log"

# Overlay local DotOS vendor + our modified device tree
mkdir -p vendor device/xiaomi kernel/xiaomi
rm -rf vendor/dot
cp -a "$PORT/vendor_dot" vendor/dot
# Prefer our port-branch device tree (has dot_rosy.mk)
rsync -a --delete --exclude .git "$PORT/trees/device_xiaomi_rosy/" device/xiaomi/rosy/
rsync -a --delete --exclude .git "$PORT/trees/kernel_xiaomi_rosy/" kernel/xiaomi/rosy/
rsync -a --delete --exclude .git "$PORT/trees/vendor_xiaomi_rosy/" vendor/xiaomi/rosy/

chmod 755 vendor/dot/prebuilt/common/bin/*.sh || true
echo "==> trees linked. Next: ./scripts/build-dot-a17.sh"
