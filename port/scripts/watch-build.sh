#!/usr/bin/env bash
# Live dashboard for the LopsiDroid soong/ninja build.
PORT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$PORT/logs/build-dot-a17-container.log"

while :; do
  # -x matches the exact process name, so this cannot match its own cmdline
  if ! container exec lopsi-aosp bash -c 'pgrep -x soong_build >/dev/null || pgrep -x ninja >/dev/null' 2>/dev/null; then
    printf '\n=== BUILD EXITED at %s ===\n\n' "$(date '+%H:%M:%S')"
    tail -30 "$LOG"
    exit 0
  fi

  printf '\033[H\033[2J'
  echo "=== $(date '+%H:%M:%S')  |  host load: $(uptime | sed 's/.*load average: //') ==="
  echo
  container exec lopsi-aosp bash -c '
    ps -eo etime,pcpu,rss,comm --sort=-pcpu | head -4 | awk "NR==1{print \"  ELAPSED   %CPU   RSS      PROCESS\"} NR>1{printf \"  %-9s %-5s %-7.1f %s\n\", \$1, \$2, \$3/1048576, \$4}"
    echo
    free -m | awk "NR==2{printf \"  MEM:  %s used / %s total, %s available\n\", \$3, \$2, \$7}"
    swapon --show 2>/dev/null | tail -n +2 | awk "{u+=\$4; printf \"  SWAP: %.1fG used\n\", u/1048576}"
    [ -z "$(swapon --show 2>/dev/null | tail -n +2)" ] && echo "  SWAP: 0 used"
    echo
    if [ -f /aosp/out/.ninja_log ]; then
      echo "  ninja edges logged: $(wc -l < /aosp/out/.ninja_log)"
    fi
    ls -la --time-style=+%H:%M /aosp/out/soong/build.dot_rosy.ninja 2>/dev/null | awk "{print \"  soong ninja: \$6 \$7\"}"
  '
  sleep 20
done
