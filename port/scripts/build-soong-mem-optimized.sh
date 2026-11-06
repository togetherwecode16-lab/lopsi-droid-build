#!/usr/bin/env bash
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${CONTAINER_NAME:-lopsi-aosp}"
IMAGE="${CONTAINER_IMAGE:-local/aosp-ubuntu:24.04}"
JOBS="${BUILD_JOBS:-4}"
TARGET="${BUILD_TARGET:-otapackage}"
LOG="$PORT/logs/build-soong-mem-opt.log"
mkdir -p "$PORT/logs" "$PORT/ccache"

container system status >/dev/null 2>&1 || container system start

if ! container ls -a 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME"; then
  container run -d --name "$NAME" --rosetta -c 10 -m "${CONTAINER_MEMORY:-12G}" --cap-add ALL \
    -v "$PORT/aosp:/aosp" -v "$PORT/ccache:/ccache" -v "$PORT:/port" \
    "$IMAGE" sleep infinity
elif ! container ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME"; then
  container start "$NAME"
fi

"$PORT/scripts/overlay-trees.sh"
rm -f "$PORT/aosp/out/.lock" "$PORT/aosp/out/.path_interposer_log" "$PORT/aosp/out/.lock_*" 2>/dev/null || true

echo "CONTAINER_BUILD_START $(date -u +%FT%TZ) target=$TARGET jobs=$JOBS" | tee -a "$LOG"
set +e
container exec -e JOBS="$JOBS" -e TARGET="$TARGET" \
  -e GOMEMLIMIT="${GOMEMLIMIT:-4GiB}" -e GOGC="${GOGC:-20}" \
  "$NAME" bash -c '
cd /aosp
rm -f out/.lock out/.path_interposer_log out/.lock_* 2>/dev/null || true
export JAVA_HOME=/aosp/prebuilts/jdk/jdk21/linux-arm64
export PATH="$JAVA_HOME/bin:$PATH"
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/ccache CCACHE_NOCOMPRESS=1 CCACHE_NOHASHDIR=1
ccache -M 50G >/dev/null
export SOONG_NINJA=ninja ALLOW_MISSING_DEPENDENCIES=true BUILD_BROKEN_DUP_RULES=true \
  WITHOUT_CHECK_API=true WITH_DEXPREOPT=false DISABLE_ARTIFACT_PATH_REQUIREMENTS=true LOPSI_NO_WINDOWS=1 \
  SOONG_UI_REGEN_ONLY=false
export TARGET_PRODUCT=dot_rosy TARGET_RELEASE=trunk_staging TARGET_BUILD_VARIANT=userdebug
# Let soong decide parallelism based on memory
export SOONG_PARALLEL_COMPILE_MEASURE_TIMINGS=true
# Aggressive memory limits to prevent container freeze
ulimit -v $((6*1024*1024)) 2>/dev/null || true
exec env GOMEMLIMIT='"${GOMEMLIMIT:-4GiB}"' GOGC='"${GOGC:-20}"' build/soong/soong_ui.bash --make-mode -j"$JOBS" "$TARGET"
' 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "CONTAINER_BUILD_EXIT rc=$rc $(date -u +%FT%TZ)" | tee -a "$LOG"
exit "$rc"
