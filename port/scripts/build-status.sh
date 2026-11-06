#!/usr/bin/env bash
# One-line build status fingerprint. Cheap: no find, no polling loops.
PORT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${CONTAINER_NAME:-lopsi-aosp}"
LOG="$PORT/logs/build-dot-a17-container.log"

# Phase: a live process beats any log line, because the log's last
# CONTAINER_BUILD_EXIT is usually from an *earlier* run.
if [ -n "$(container exec "$NAME" pgrep -f '/bin/soong_build --top' 2>/dev/null)" ]; then
  phase=SOONG_ANALYSIS
elif [ -n "$(container exec "$NAME" pgrep -f 'out/soong_ui' 2>/dev/null)" ]; then
  phase=NINJA_COMPILE
elif [ -n "$(container exec "$NAME" pgrep -f 'build-tools/linux-arm64/bin/ninja' 2>/dev/null)" ]; then
  phase=NINJA_COMPILE
elif [ -n "$(container ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$NAME" && echo x)" ]; then
  # Container up but no build: exited only if the newest start line has a
  # matching exit line after it.
  last_start=$(grep -n "CONTAINER_BUILD_START" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
  last_exit=$(grep -n "CONTAINER_BUILD_EXIT" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
  if [ -n "$last_start" ] && [ -n "$last_exit" ] && [ "$last_exit" -gt "$last_start" ]; then
    phase=EXITED
  else
    phase=CONTAINER_IDLE
  fi
else
  phase=CONTAINER_DOWN
fi

mem=$(container exec "$NAME" free -m 2>/dev/null | awk 'NR==2{printf "mem_used=%sM avail=%sM", $3, $7}')
rss=$(container exec "$NAME" bash -c \
  'p=$(ps -eo pid,args|grep "/bin/soong_build --top"|grep -v grep|awk "{print \$1}"|head -1); \
   [ -n "$p" ] && ps -o etime=,pcpu=,rss= -p "$p" | awk "{printf \"soong elapsed=%s cpu=%s rss=%dM\", \$1, \$2, \$3/1024}"' \
  2>/dev/null)
ninja_ts=$(ls -la "$PORT/aosp/out/soong/build.dot_rosy.ninja" 2>/dev/null | awk '{print $6,$7,$8}')

echo "phase=$phase $mem ${rss:-soong=none} ninja_mtime=[${ninja_ts:-none}]"
tail -1 "$LOG" 2>/dev/null | cut -c1-110