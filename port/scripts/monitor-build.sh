#!/usr/bin/env bash
# Persistently summarize the LopsiDroid Android build. Safe to run alongside builds.
set -u

PORT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$PORT/logs"
OUT_DIR="$PORT/out"
STATUS="$OUT_DIR/COMPILE_STATUS.txt"
HISTORY="$LOG_DIR/compile-monitor.log"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-300}"
# User-agreed delivery target. Override only when the deadline changes.
BUILD_DEADLINE="${BUILD_DEADLINE:-2026-09-19 13:00:00 IST}"

mkdir -p "$LOG_DIR" "$OUT_DIR"

latest_log() {
  local candidate newest=0 newest_file=""
  for candidate in "$LOG_DIR/school-day-build.log" "$OUT_DIR/build-dot-a17-docker.log" "$LOG_DIR/first-build.log" "$LOG_DIR/build-dot-a17.log"; do
    [[ -f "$candidate" ]] || continue
    local mtime
    mtime=$(stat -f '%m' "$candidate" 2>/dev/null || echo 0)
    if (( mtime > newest )); then
      newest=$mtime
      newest_file=$candidate
    fi
  done
  printf '%s\n' "$newest_file"
}

check_once() {
  local now deadline_epoch remaining log log_mtime age state zip latest_attempt errors
  now=$(date +%s)
  deadline_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S %Z' "$BUILD_DEADLINE" +%s 2>/dev/null || echo 0)
  log=$(latest_log)
  zip=$(find "$OUT_DIR" -maxdepth 2 -type f -name '*.zip' -size +80M -print -quit 2>/dev/null || true)

  if [[ -n "$zip" ]]; then
    state="COMPLETE"
  elif [[ -z "$log" ]]; then
    state="NO_BUILD_LOG"
  else
    log_mtime=$(stat -f '%m' "$log" 2>/dev/null || echo 0)
    age=$((now - log_mtime))
    if (( age <= INTERVAL_SECONDS + 120 )); then
      state="RUNNING_OR_RECENT"
    else
      state="STALE_OR_STOPPED"
    fi
  fi

  if [[ -z "$zip" && "$deadline_epoch" -gt 0 && "$now" -gt "$deadline_epoch" ]]; then
    state="DEADLINE_MISSED"
  fi

  latest_attempt=""
  errors=""
  if [[ -n "$log" ]]; then
    # The school-day loop appends attempts. Scan only the most recent one so
    # errors from a retried build do not masquerade as failures in this attempt.
    latest_attempt=$(awk '/start attempt #[0-9]+/{line=NR} END{print line+0}' "$log")
    if [[ "$latest_attempt" -gt 0 ]]; then
      errors=$(tail -n +"$latest_attempt" "$log" | grep -Ei \
        '(^|[^[:alpha:]])(error:|fatal:|failed:|build_failed|ninja: build stopped|soong bootstrap failed|out of memory|segmentation fault|killed)' \
        | tail -8 || true)
    else
      errors=$(grep -Ei \
        '(^|[^[:alpha:]])(error:|fatal:|failed:|build_failed|ninja: build stopped|soong bootstrap failed|out of memory|segmentation fault|killed)' \
        "$log" | tail -8 || true)
    fi
  fi

  {
    echo "LopsiDroid compile monitor"
    echo "Checked: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "State: $state"
    if [[ "$deadline_epoch" -gt 0 ]]; then
      remaining=$((deadline_epoch - now))
      echo "Deadline: $BUILD_DEADLINE (remaining: ${remaining}s)"
    fi
    [[ -n "$log" ]] && echo "Log: ${log#$PORT/} (last write: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %Z' "$log"))"
    [[ -n "$log" ]] && echo "Log age: $((now - $(stat -f '%m' "$log")))s"
    [[ -n "$zip" ]] && echo "Flashable ZIP: $zip"
    if [[ -n "$errors" ]]; then
      echo "Current-attempt errors:"
      printf '%s\n' "$errors"
    else
      echo "Current-attempt errors: none detected"
    fi
  } >"$STATUS"

  printf '%s state=%s log=%s errors=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$state" "${log#$PORT/}" \
    "$([[ -n "$errors" ]] && echo yes || echo no)" >>"$HISTORY"
}

if [[ "${1:-}" == "--once" ]]; then
  check_once
  exit 0
fi

while true; do
  check_once
  sleep "$INTERVAL_SECONDS"
done
