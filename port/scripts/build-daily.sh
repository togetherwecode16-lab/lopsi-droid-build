#!/usr/bin/env bash
# DAILY LopsiDroid rebuild — target 20-30 minutes.
# Requires: warm aosp/out + port/ccache from the first (long) build. Never cleans.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
AOSP="${AOSP_DIR:-$PORT/aosp}"
IMG=lopsidot-aosp-builder:ubuntu2204
CCACHE_DIR="${CCACHE_DIR:-$PORT/ccache}"
OUT_HOST="${OUT_HOST:-$PORT/out}"
BUILD_MAX_MINUTES="${BUILD_MAX_MINUTES:-30}"
NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 10)"
export PATH="/opt/homebrew/bin:$PATH"

if [ ! -f "$AOSP/build/envsetup.sh" ]; then
  echo "AOSP tree incomplete."
  exit 1
fi
if [ ! -d "$AOSP/out" ] || [ -z "$(ls -A "$AOSP/out" 2>/dev/null || true)" ]; then
  echo "No warm out/ yet — run full build once first (daily 20-30m needs a primed tree)."
  echo "After that, use this script and never delete aosp/out or port/ccache."
  exit 1
fi

mkdir -p "$CCACHE_DIR" "$OUT_HOST"
"$PORT/scripts/protect-build-cache.sh" >/dev/null 2>&1 || true
"$PORT/scripts/overlay-trees.sh"

# Keep Colima up (12GB) — restarting cold hurts daily time
if command -v colima >/dev/null 2>&1; then
  if ! colima status 2>/dev/null | grep -qi Running; then
    colima start --cpu 10 --memory 12 --disk 200 --vm-type=vz --mount-type=virtiofs
  fi
  docker context use colima >/dev/null 2>&1 || true
fi

DOCKER_MEM_G=11
docker info 2>/dev/null | grep -q 'Total Memory: 7' && DOCKER_MEM_G=7

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  docker build --platform linux/amd64 -t "$IMG" -f "$PORT/docker/Dockerfile.builder" "$PORT/docker"
fi

echo "DAILY_BUILD budget=${BUILD_MAX_MINUTES}m j=$NPROC mem=${DOCKER_MEM_G}g platform=amd64"

docker run --rm -i \
  --platform linux/amd64 \
  --cpus="$NPROC" \
  --memory="${DOCKER_MEM_G}g" \
  --memory-swap="${DOCKER_MEM_G}g" \
  --ulimit nofile=1048576:1048576 \
  -e USE_CCACHE=1 \
  -e CCACHE_EXEC=/usr/bin/ccache \
  -e CCACHE_DIR=/ccache \
  -e CCACHE_COMPRESS=1 \
  -e CCACHE_COMPRESSLEVEL=1 \
  -e CCACHE_MAXSIZE=50G \
  -e CCACHE_SLOPPINESS=file_macro,time_macros,include_file_mtime,include_file_ctime,file_stat_matches,pch_defines \
  -e BUILD_MAX_MINUTES="$BUILD_MAX_MINUTES" \
  -v "$AOSP:/aosp" \
  -v "$OUT_HOST:/out" \
  -v "$CCACHE_DIR:/ccache" \
  -w /aosp \
  "$IMG" \
  bash -lc '
    set -euo pipefail
    ulimit -n 1048576 || ulimit -n 65536 || true
    ccache -M 50G >/dev/null
    # DO NOT ccache -z or make clean — kills daily speed
    source build/envsetup.sh
    lunch dot_rosy-trunk_staging-userdebug \
      || lunch dot_rosy trunk_staging userdebug \
      || lunch aosp_arm64-trunk_staging-eng

    export TARGET_PRODUCT="${TARGET_PRODUCT:-dot_rosy}"
    export TARGET_RELEASE="${TARGET_RELEASE:-trunk_staging}"
    export TARGET_BUILD_VARIANT="${TARGET_BUILD_VARIANT:-userdebug}"
    echo "LUNCH_OK PRODUCT=$TARGET_PRODUCT RELEASE=$TARGET_RELEASE VARIANT=$TARGET_BUILD_VARIANT"

    export WITH_DEXPREOPT=false
    export DONT_DEXPREOPT_PREBUILTS=true
    export USE_DEX2OAT_DEBUG=false
    # Keep normal API stubs: source stubs make incremental builds slower.
    unset WITHOUT_CHECK_API BUILD_FROM_SOURCE_STUB || true
    export SOONG_NINJA=ninja
    unset SOONG_UI_NINJA_ARGS || true
    export NINJA_ARGS="-j$(nproc)"

    SECONDS=0
    MAX_SEC=$(( BUILD_MAX_MINUTES * 60 ))
    set +e
    # Incremental otapackage — only rebuilds what changed
    m -j$(nproc) TARGET_PRODUCT="$TARGET_PRODUCT" TARGET_RELEASE="$TARGET_RELEASE" TARGET_BUILD_VARIANT="$TARGET_BUILD_VARIANT" otapackage 2>&1 | tee /out/build-daily.log
    rc=${PIPESTATUS[0]}
    set -e
    echo "=== daily elapsed ${SECONDS}s / budget ${MAX_SEC}s ==="
    ccache -s | head -20 || true
    find out/target/product -maxdepth 2 -name "*.zip" -type f 2>/dev/null | while read -r z; do
      cp -f "$z" "/out/$(basename "$z")"
      ls -lh "/out/$(basename "$z")"
    done
    if [[ "$rc" -ne 0 ]]; then
      echo "BUILD_FAILED rc=$rc"
      exit "$rc"
    fi
    if [[ "$SECONDS" -gt "$MAX_SEC" ]]; then
      echo "OVER_${BUILD_MAX_MINUTES}M — change was probably too large (framework/kernel). Small vendor/app edits should be under budget."
      exit 2
    fi
    echo DAILY_BUILD_DONE
  '
