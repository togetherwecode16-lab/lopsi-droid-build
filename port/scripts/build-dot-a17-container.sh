#!/usr/bin/env bash
# Build dot_rosy otapackage inside Apple `container` (no Docker/Colima).
# Soong/go run natively on arm64; x86_64 prebuilts (clang, jdk) run via Rosetta.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${CONTAINER_NAME:-lopsi-aosp}"
IMAGE="${CONTAINER_IMAGE:-local/aosp-ubuntu:24.04}"
JOBS="${BUILD_JOBS:-12}"
TARGET="${BUILD_TARGET:-otapackage}"
LOG="$PORT/logs/build-dot-a17-container.log"
mkdir -p "$PORT/logs" "$PORT/ccache"

container system status >/dev/null 2>&1 || container system start

if ! container ls -a 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME"; then
  container run -d --name "$NAME" --rosetta -c 10 -m "${CONTAINER_MEMORY:-16G}" --cap-add ALL \
    -v "$PORT/aosp:/aosp" -v "$PORT/ccache:/ccache" -v "$PORT:/port" \
    "$IMAGE" sleep infinity
elif ! container ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME"; then
  container start "$NAME"
fi

# One-time provisioning: amd64 loader/libs for Rosetta prebuilts + host tools + swap
container exec "$NAME" bash -c '
set -e
if [ ! -e /lib64/ld-linux-x86-64.so.2 ] || ! command -v ccache >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  f=/etc/apt/sources.list.d/ubuntu.sources
  grep -q "^Architectures: arm64" $f || sed -i "/^Types:/a Architectures: arm64" $f
  printf "Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: noble noble-updates noble-security\nComponents: main universe\nArchitectures: amd64\n" >/etc/apt/sources.list.d/amd64.sources
  dpkg --add-architecture amd64
  apt-get update -qq
  apt-get install -y -qq rsync zip unzip ccache python-is-python3 m4 bison flex lz4 file bc cpio procps \
    libc6:amd64 libstdc++6:amd64 zlib1g:amd64 libncurses6:amd64 libtinfo6:amd64 libgcc-s1:amd64 libssl3t64:amd64 libexpat1:amd64 >/dev/null
fi
# not persistent across container restarts; without it every x86 prebuilt fails
mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
if ! swapon --show | grep -q /swapfile; then
  [ -f /swapfile ] || { fallocate -l 24G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; }
  swapon /swapfile
fi
if ! swapon --show | grep -q /swapfile2; then
  [ -f /swapfile2 ] || { fallocate -l 16G /swapfile2; chmod 600 /swapfile2; mkswap /swapfile2 >/dev/null; }
  swapon /swapfile2
fi
'

"$PORT/scripts/overlay-trees.sh"
rm -f "$PORT/aosp/out/.path_interposer_log" "$PORT/aosp/out/.lock"

echo "CONTAINER_BUILD_START $(date -u +%FT%TZ) target=$TARGET jobs=$JOBS" | tee -a "$LOG"
set +e
container exec -e JOBS="$JOBS" -e TARGET="$TARGET" -e NINJA_ONLY="${NINJA_ONLY:-0}" \
  -e ROSY_GOMEMLIMIT="${ROSY_GOMEMLIMIT:-9GiB}" -e ROSY_GOGC="${ROSY_GOGC:-40}" "$NAME" bash -c '
cd /aosp
rm -f out/.lock
export JAVA_HOME=/aosp/prebuilts/jdk/jdk21/linux-arm64
# sbox genrules call bare `java`. The image java is 8; host tools are class version 65.
export PATH="$JAVA_HOME/bin:$PATH"
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/ccache CCACHE_NOCOMPRESS=1 CCACHE_NOHASHDIR=1
ccache -M 50G >/dev/null
export SOONG_NINJA=ninja ALLOW_MISSING_DEPENDENCIES=true BUILD_BROKEN_DUP_RULES=true \
  WITHOUT_CHECK_API=true WITH_DEXPREOPT=false DISABLE_ARTIFACT_PATH_REQUIREMENTS=true LOPSI_NO_WINDOWS=1 \
  SOONG_INCREMENTAL_ANALYSIS="${SOONG_INCREMENTAL_ANALYSIS:-true}"
export TARGET_PRODUCT=dot_rosy TARGET_RELEASE=trunk_staging TARGET_BUILD_VARIANT=userdebug
NINJA=prebuilts/build-tools/linux-arm64/bin/ninja
COMBINED=out/combined-dot_rosy.ninja
if [ "${NINJA_ONLY:-0}" = 1 ] && [ -f "$COMBINED" ]; then
  echo "NINJA_DIRECT $COMBINED"
  # 32-bit and 64-bit CTS tests install to the same host path. rosy sets
  # BUILD_BROKEN_DUP_RULES, but soong_ui still passes dupbuild=err.
  exec "$NINJA" -f "$COMBINED" -j"$JOBS" -k 0 -w dupbuild=warn -w missingdepfile=warn "$TARGET"
fi
echo "SOONG_UI_DIRECT (no lunch)"
exec build/soong/soong_ui.bash --make-mode -j"$JOBS" "$TARGET"
' 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "CONTAINER_BUILD_EXIT rc=$rc $(date -u +%FT%TZ)" | tee -a "$LOG"

if [ "$rc" -eq 0 ]; then
  "$PORT/scripts/package-lopsidot-ota.sh"
fi
exit "$rc"
