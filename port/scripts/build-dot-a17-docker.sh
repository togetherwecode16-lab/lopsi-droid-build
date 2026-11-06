#!/usr/bin/env bash
# LopsiDroid A17 first/full build — primes out/ + ccache for daily 20-30m rebuilds.
# Prefer Colima (12GB). Daily changes: scripts/build-daily.sh
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
AOSP="${AOSP_DIR:-$PORT/aosp}"
IMG=lopsidot-aosp-builder:ubuntu2204
CCACHE_DIR="${CCACHE_DIR:-$PORT/ccache}"
OUT_HOST="${OUT_HOST:-$PORT/out}"
# First/full build: no hard fail on time. Daily use: scripts/build-daily.sh (20-30m).
BUILD_MAX_MINUTES="${BUILD_MAX_MINUTES:-0}"
DAILY_TARGET_MINUTES=30
NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 10)"

prefer_colima() {
  if ! command -v colima >/dev/null 2>&1; then
    return 1
  fi
  # Rosetta for amd64 AOSP prebuilts — far faster than qemu-user (keeps host out/ bind mount)
  # colima status prints to stderr — do not discard
  if ! colima status 2>&1 | grep -qi running; then
    echo "COLIMA_START cpu=10 memory=12 disk=200 vz+rosetta mount=sshfs"
    # sshfs avoids virtiofs EMFILE on Mac kern.maxfilesperproc=65536 during soong walks
    colima start --cpu 10 --memory 12 --disk 200 --vm-type=vz --vz-rosetta --mount-type=sshfs || \
      colima start --cpu 10 --memory 12 --disk 200 --vm-type=vz --vz-rosetta --mount-type=virtiofs || \
      colima start --cpu 10 --memory 12 --disk 200 --vm-type=vz --vz-rosetta
  fi
  docker context use colima >/dev/null 2>&1 || true
  local mem
  mem="$(docker info 2>/dev/null | awk '/Total Memory/{print $3$4}')"
  echo "DOCKER_ENGINE mem=$mem cpus=$(docker info 2>/dev/null | awk '/CPUs/{print $2; exit}') rosetta=on"
}

if [ ! -f "$AOSP/build/envsetup.sh" ]; then
  echo "AOSP tree incomplete. Wait for sync to finish."
  exit 1
fi

mkdir -p "$CCACHE_DIR" "$OUT_HOST"
"$PORT/scripts/protect-build-cache.sh" >/dev/null 2>&1 || true
"$PORT/scripts/overlay-trees.sh"

prefer_colima || echo "WARN: Colima unavailable — using current Docker engine (may be ~8GB)"

# Docker memory for run: ask for 11g inside a 12g VM
DOCKER_MEM_G=12
if docker info 2>/dev/null | grep -q 'Total Memory: 7'; then
  DOCKER_MEM_G=7
  echo "WARN: engine only ~8GB"
fi

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
  docker build --platform linux/amd64 -t "$IMG" -f "$PORT/docker/Dockerfile.builder" "$PORT/docker"
fi

echo "BUILD_CFG platform=linux/amd64 nproc=$NPROC docker_mem=${DOCKER_MEM_G}g (AOSP needs x86 prebuilts)"
echo "SPEED: ccache on, dexpreopt off, -j$NPROC — primes daily 20-30m"

# OUT on VM-local docker volume (ext4). sshfs/virtiofs cannot bind unix sockets
# (soong path_interposer: bind: operation not permitted on out/.path_interposer_log).
OUT_VOL=lopsidot-aosp-out
docker volume create "$OUT_VOL" >/dev/null
echo "OUT_VOL=$OUT_VOL (local ext4 — not sshfs)"

# --platform linux/amd64: AOSP prebuilts are linux-x86 (no linux-arm64 go/clang host)
# BUILD_J: ninja parallelism (default 1048576 / "1M" per operator request)
BUILD_J="${BUILD_J:-1048576}"
docker run --rm -i \
  --platform linux/amd64 \
  --privileged \
  --cpus="$NPROC" \
  --memory="${DOCKER_MEM_G}g" \
  --memory-swap="20g" \
  --ulimit nofile=1048576:1048576 \
  --ulimit nproc=1048576:1048576 \
  -e USE_CCACHE=1 \
  -e CCACHE_EXEC=/usr/bin/ccache \
  -e CCACHE_DIR=/ccache \
  -e CCACHE_NOCOMPRESS=1 \
  -e CCACHE_MAXSIZE=50G \
  -e BUILD_MAX_MINUTES="$BUILD_MAX_MINUTES" \
  -e BUILD_J="$BUILD_J" \
  -e BUILD_GOMAXPROCS="${BUILD_GOMAXPROCS:-1}" \
  -e OUT_DIR=/aosp/out \
  -v "$AOSP:/aosp" \
  -v "$OUT_VOL:/aosp/out" \
  -v "$OUT_HOST:/out" \
  -v "$CCACHE_DIR:/ccache" \
  -v "$PORT/scripts:/scripts:ro" \
  -w /aosp \
  "$IMG" \
  bash -lc '
    set -euo pipefail
    # Disable OOM killer for soong_build — it needs ~13GB and gets killed at peak
    echo -17 > /proc/$$/oom_score_adj 2>/dev/null || true
    # Also disable the cgroup OOM killer
    echo 1 > /proc/sys/vm/overcommit_memory 2>/dev/null || true
    echo 1000000000 > /proc/sys/vm/overcommit_ratio 2>/dev/null || true
    # Max practical open-files (highest Docker will grant on this VM)
    ulimit -n 1048576 2>/dev/null || ulimit -n 65536 || true
    ulimit -u 1048576 2>/dev/null || true
    echo "ulimit_nofile=$(ulimit -n) ulimit_nproc=$(ulimit -u)"
    export ULIMIT_NOFILE="$(ulimit -n)"
    HOST_NPROC="$(nproc 2>/dev/null || echo 8)"
    # -j1M + GOMAXPROCS=1M per operator (tested OK on this machine)
    J="${BUILD_J:-1048576}"
    export GOMAXPROCS="${BUILD_GOMAXPROCS:-$J}"
    export NINJA_ARGS="-j${J}"
    echo "FD_GUARD GOMAXPROCS=$GOMAXPROCS J=$J ulimit=$ULIMIT_NOFILE"
    export OUT_DIR=/aosp/out
    mkdir -p "$OUT_DIR"
    echo "OUT_DIR=$OUT_DIR (docker volume — unix sockets OK)"
    unset CCACHE_COMPRESS || true
    export CCACHE_NOCOMPRESS=1
    ccache -M 50G >/dev/null
    # Rosetta: soong dumpvars calls absolute `prebuilts/go/.../bin/go env GOROOT`
    # which wedges at 99% CPU. That binary is wrapped (go.real + shim).
    # Do NOT export GOROOT — go then errors "GOROOT variable is being overridden".
    unset GOROOT || true
    export PATH="/out/bin:/aosp/prebuilts/go/linux-x86/bin:$PATH"
    export GOTOOLCHAIN=local
    echo "GO_SHIM $(command -v go) -> $(go env GOROOT 2>/dev/null || true)"
    # Keep cache forever — primes daily 20-30m builds
    source build/envsetup.sh
    # AOSP 17+: product-release-variant (legacy product-variant is rejected)
    lunch dot_rosy-trunk_staging-userdebug \
      || lunch dot_rosy trunk_staging userdebug \
      || lunch aosp_arm64-trunk_staging-eng

    # Insurance: lunch dumpvars under Rosetta can leave TARGET_RELEASE unset,
    # which fails kati with release_config.mk "No release config set".
    export TARGET_PRODUCT="${TARGET_PRODUCT:-dot_rosy}"
    export TARGET_RELEASE="${TARGET_RELEASE:-trunk_staging}"
    export TARGET_BUILD_VARIANT="${TARGET_BUILD_VARIANT:-userdebug}"
    echo "LUNCH_OK PRODUCT=$TARGET_PRODUCT RELEASE=$TARGET_RELEASE VARIANT=$TARGET_BUILD_VARIANT"

    export WITH_DEXPREOPT=false
    export DONT_DEXPREOPT_PREBUILTS=true
    export USE_DEX2OAT_DEBUG=false
    # Standard API stubs are substantially faster than source-generated stubs.
    # Do not set WITHOUT_CHECK_API: current libcore rejects that mode unless it
    # generates source stubs, which both caused the bootstrap failure and slows
    # incremental builds.
    unset WITHOUT_CHECK_API BUILD_FROM_SOURCE_STUB || true
    export DISABLE_ARTIFACT_PATH_REQUIREMENTS=true
    export BUILD_BROKEN_MISSING_REQUIRED_MODULES=true
    export ALLOW_MISSING_DEPENDENCIES=true
    export BUILD_BROKEN_DUP_RULES=true
    # Prefer soong incremental if available
    # Incremental analysis loads entire previous graph into RAM causing >13GB OOM spike
    export SOONG_INCREMENTAL_ANALYSIS=false
    export SOONG_USE_PARTIAL_COMPILE=
    unset SOONG_USE_PARTIAL_COMPILE || true
    export CCACHE_SLOPPINESS=file_macro,time_macros,include_file_mtime,include_file_ctime,file_stat_matches,pch_defines
    export CCACHE_NOHASHDIR=1
    # Force classic ninja — trunk_staging defaults to siso, and SOONG_UI_NINJA_ARGS=-jN
    # makes siso bootstrap exit 2 (prints help). Do NOT set SOONG_UI_NINJA_ARGS.
    export SOONG_NINJA=ninja
    unset SOONG_UI_NINJA_ARGS || true
    # SISO_MAIN_FIX: soong ensureSymlink to build/soong/siso_config can break under docker mounts; materialize main/
    mkdir -p "$OUT_DIR/siso_config/main"
    cp -a build/soong/siso_config/. "$OUT_DIR/siso_config/main/" 2>/dev/null || true
    # Keep jackson/aws/gcp Android.bp paths discoverable after park/restore
    if [ -f /out/restored_android_bp.seed ]; then
      mkdir -p "$OUT_DIR/.module_paths"
      module_paths="$OUT_DIR/.module_paths/Android.bp.list"
      module_paths_tmp="$(mktemp)"
      { cat "$module_paths" 2>/dev/null || true; cat /out/restored_android_bp.seed; } | sort -u > "$module_paths_tmp"
      # Do not touch this Soong input when it is already identical; a changed
      # mtime forces an expensive graph regeneration on every retry.
      if ! cmp -s "$module_paths_tmp" "$module_paths"; then
        mv "$module_paths_tmp" "$module_paths"
      else
        rm -f "$module_paths_tmp"
      fi
    fi
    # The host has only 16GiB and Docker receives ~12GiB.  Soong is being
    # OOM-killed during bootstrap; keep Go memory fan-out bounded.
    # Hard-clamp GOMAXPROCS=1
    export GOMAXPROCS=1
    export GOFLAGS="-p=1"
    export GOGC=5
    export GOMEMLIMIT=7500MiB
    export ROSY_SKIP_GLOBS=1
    echo "GOMAXPROCS=1 GOGC=5 GOMEMLIMIT=7500MiB ROSY_SKIP_GLOBS=1"
    # Background watcher: make soong_build unkillable by OOM as soon as it spawns
    ( while true; do
        for proc in soong_build soong_ui; do
          pid=$(pgrep -x $proc 2>/dev/null | head -1)
          if [ -n "$pid" ]; then
            echo -1000 > /proc/$pid/oom_score_adj 2>/dev/null || true
          fi
        done
        sleep 2
      done ) &
    J_NINJA="${NINJA_JOBS:-10}"
    export NINJA_ARGS="-j${J_NINJA}"
    echo "SPEED_JOBS=j${J_NINJA} (ninja) GOMAXPROCS=$GOMAXPROCS SOONG_NINJA=$SOONG_NINJA OUT_DIR=$OUT_DIR"

    # After soong writes the ninja file, back it up so future runs skip soong entirely
    ( while true; do
        if [ -f /aosp/out/soong/build.dot_rosy.ninja ] && [ -s /aosp/out/soong/build.dot_rosy.ninja ]; then
          cp -f /aosp/out/soong/build.dot_rosy.ninja /out/build.dot_rosy.ninja.bak
          echo "NINJA_BACKED_UP $(ls -lh /out/build.dot_rosy.ninja.bak)"
          break
        fi
        sleep 5
      done ) &
    SECONDS=0
    set +e
    m -j${J_NINJA} TARGET_PRODUCT="$TARGET_PRODUCT" TARGET_RELEASE="$TARGET_RELEASE" TARGET_BUILD_VARIANT="$TARGET_BUILD_VARIANT" otapackage 2>&1 | tee /out/build-dot-a17-docker.log
    rc=${PIPESTATUS[0]}
    set -e
    echo "=== first/full elapsed ${SECONDS}s ==="
    ccache -s || true
    find "$OUT_DIR/target/product" -maxdepth 2 -name "*.zip" -type f 2>/dev/null | while read -r z; do
      cp -f "$z" "/out/$(basename "$z")"
      ls -lh "/out/$(basename "$z")"
    done
    if [[ "$rc" -ne 0 ]]; then
      echo "BUILD_FAILED rc=$rc"
      exit "$rc"
    fi
    echo "BUILD_DONE — keep docker vol lopsidot-aosp-out + port/ccache. Daily: scripts/build-daily.sh (target 20-30m)"
  '
