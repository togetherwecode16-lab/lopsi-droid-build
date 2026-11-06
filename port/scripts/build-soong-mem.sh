#!/usr/bin/env bash
set -euo pipefail

PORT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER="/opt/homebrew/bin/container"
NAME="${CONTAINER_NAME:-lopsi-aosp}"
IMAGE="${CONTAINER_IMAGE:-local/aosp-ubuntu:24.04}"
JOBS="${BUILD_JOBS:-1}"
TARGET="${BUILD_TARGET:-otapackage}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-16G}"
GOMEMLIMIT="3GiB"
GOGC="2"
LOG="$PORT/logs/build-soong-mem.log"
mkdir -p "$PORT/logs" "$PORT/ccache"

$CONTAINER system status >/dev/null 2>&1 || $CONTAINER system start

if ! $CONTAINER ls -a 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME"; then
  $CONTAINER run -d --name "$NAME" --rosetta -c 10 -m "${CONTAINER_MEMORY}" --cap-add ALL \
    -v "$PORT/aosp:/aosp" -v "$PORT/ccache:/ccache" -v "$PORT:/port" \
    "$IMAGE" sleep infinity
elif ! $CONTAINER ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME"; then
  $CONTAINER start "$NAME"
fi

"$PORT/scripts/overlay-trees.sh"
rm -f "$PORT/aosp/out/.lock" "$PORT/aosp/out/.path_interposer_log"

echo "CONTAINER_BUILD_START $(date -u +%FT%TZ) target=$TARGET jobs=$JOBS mem=${CONTAINER_MEMORY} gomemlimit=${GOMEMLIMIT} gogc=${GOGC}" > "$LOG"
set +e

$CONTAINER exec -e JOBS="$JOBS" -e TARGET="$TARGET" \
  -e GOMEMLIMIT="${GOMEMLIMIT}" -e GOGC="${GOGC}" \
  "$NAME" bash -c '
cd /aosp
rm -f out/.lock
export JAVA_HOME=/aosp/prebuilts/jdk/jdk21/linux-arm64
export PATH="$JAVA_HOME/bin:$PATH"
export USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/ccache CCACHE_NOCOMPRESS=1 CCACHE_NOHASHDIR=1
export SOONG_NINJA=ninja ALLOW_MISSING_DEPENDENCIES=true BUILD_BROKEN_DUP_RULES=true \
  WITHOUT_CHECK_API=true WITH_DEXPREOPT=false DISABLE_ARTIFACT_PATH_REQUIREMENTS=true \
  LOPSI_NO_WINDOWS=1 SOONG_UI_REGEN_ONLY=false && \
exec env GOMEMLIMIT="3GiB" GOGC="2" TARGET_PRODUCT=dot_rosy TARGET_RELEASE=trunk_staging TARGET_BUILD_VARIANT=userdebug build/soong/soong_ui.bash --make-mode -j1 otapackage
'

EXIT_CODE=$?
echo "CONTAINER_BUILD_END $(date -u +%FT%TZ) exit_code=$EXIT_CODE" >> "$LOG"
exit $EXIT_CODE
