#!/usr/bin/env bash
# Every 5 minutes: if LopsiDroid build zip is ready AND Redmi 5 (rosy) is connected → flash.
# Phone missing / unplugged must NEVER stop the build or this watcher.
# On boot failure → wipe/reflash/retry loop.
set -u
PORT="/Users/mridultyagi/Downloads/LineagePhone/port"
ROOT="/Users/mridultyagi/Downloads/LineagePhone"
LOG="$PORT/logs/overnight-flash.log"
STATUS="$PORT/out/FLASH_STATUS.txt"
ADB="${ADB:-/Users/mridultyagi/adb}"
FASTBOOT="${FASTBOOT:-/Users/mridultyagi/fastboot}"
TWRP_CANDIDATES=(
  "$ROOT/downloads/recovery/twrp-rosy.img"
  "$ROOT/downloads/recovery/twrp-3.7.0_9-0-rosy.img"
  "$HOME/Downloads/recovery.img"
  "$ROOT/backups/flash-fix/recovery.img"
)
RETRO="$ROOT/downloads/firmware/rosy-retrofit-converter.zip"
INTERVAL=300  # 5 minutes
MAX_FLASH_ATTEMPTS=8
FLASHED_MARKER="$PORT/out/.last_flashed_zip"

export PATH="$(dirname "$ADB"):/opt/homebrew/bin:$HOME/bin:$PATH"
mkdir -p "$PORT/logs" "$PORT/out" "$ROOT/downloads/recovery"
exec >>"$LOG" 2>&1

log() { echo "$(date '+%F %T') $*"; }

write_status() {
  {
    echo "Flash watcher — $(date)"
    echo "$*"
    echo
    echo "Build process: $(pgrep -f build-dot-a17-docker >/dev/null && echo RUNNING || echo not-running)"
    echo "Phone (adb):"; "$ADB" devices -l 2>/dev/null || true
    echo "Phone (fastboot):"; "$FASTBOOT" devices 2>/dev/null || true
    echo "ROM zip:"; find_rom_zip || echo "(build not finished)"
  } >"$STATUS" 2>/dev/null || true
  cp -f "$STATUS" "$HOME/Desktop/LOPSIDROID_FLASH_STATUS.txt" 2>/dev/null || true
}

ensure_twrp() {
  local t
  for t in "${TWRP_CANDIDATES[@]}"; do
    if [[ -f "$t" && -s "$t" ]]; then
      # Prefer copy into downloads/recovery for consistent path
      if [[ "$t" != "$ROOT/downloads/recovery/twrp-rosy.img" ]]; then
        cp -f "$t" "$ROOT/downloads/recovery/twrp-rosy.img" 2>/dev/null || true
      fi
      echo "$ROOT/downloads/recovery/twrp-rosy.img"
      return 0
    fi
  done
  return 1
}

find_rom_zip() {
  # Prefer freshly built LopsiDroid / dot_rosy OTA (large). Never treat tiny stubs as ready.
  local z
  z=$(find "$PORT/aosp/out/target/product" "$PORT/out" -type f \( -name '*rosy*.zip' -o -name '*dot_rosy*.zip' -o -name '*Lopsi*.zip' -o -name '*ota*.zip' \) -size +80M 2>/dev/null | sort -t/ -k1 | tail -1)
  if [[ -n "${z:-}" ]]; then
    echo "$z"
    return 0
  fi
  # OUT lives on docker volume lopsidot-aosp-out — copy to host /out when ready
  if command -v docker >/dev/null 2>&1; then
    local remote
    remote=$(docker run --rm -v lopsidot-aosp-out:/aosp/out alpine \
      sh -c 'find /aosp/out/target/product -type f \( -name "*rosy*.zip" -o -name "*dot_rosy*.zip" -o -name "*Lopsi*.zip" -o -name "*ota*.zip" \) -size +80M 2>/dev/null | head -1' 2>/dev/null || true)
    if [[ -n "${remote:-}" ]]; then
      local base
      base=$(basename "$remote")
      docker run --rm -v lopsidot-aosp-out:/aosp/out -v "$PORT/out:/out" alpine \
        cp -f "$remote" "/out/$base" 2>/dev/null || true
      if [[ -f "$PORT/out/$base" ]]; then
        echo "$PORT/out/$base"
        return 0
      fi
    fi
  fi
  return 1
}

phone_mode() {
  # prints: none | adb | recovery | fastboot | sideload
  if "$FASTBOOT" devices 2>/dev/null | awk 'NF>=2{exit 0} END{exit 1}'; then
    echo fastboot
    return
  fi
  local line
  line=$("$ADB" devices 2>/dev/null | awk 'NR>1 && $1!=""{print $2; exit}')
  case "${line:-}" in
    device) echo adb ;;
    recovery) echo recovery ;;
    sideload) echo sideload ;;
    *) echo none ;;
  esac
}

is_rosy_fastboot() {
  local p
  p=$("$FASTBOOT" getvar product 2>&1 | awk -F': ' '/^product:/{print $2}' | tr -d '\r')
  [[ -z "$p" || "$p" == "rosy" || "$p" == "Redmi 5" ]]
}

wait_mode() {
  local want="$1" secs="${2:-90}"
  local i mode
  for i in $(seq 1 "$secs"); do
    mode=$(phone_mode)
    if [[ "$mode" == "$want" ]]; then
      echo "$mode"
      return 0
    fi
    # recovery sometimes shows as device
    if [[ "$want" == recovery && ( "$mode" == recovery || "$mode" == adb ) ]]; then
      if "$ADB" shell "getprop ro.twrp.version" 2>/dev/null | grep -q . \
        || "$ADB" shell "ls /twres" >/dev/null 2>&1; then
        echo recovery
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

boot_ok() {
  # sys.boot_completed after flash
  local i v
  for i in $(seq 1 180); do  # up to ~15 min first boot
    if [[ "$(phone_mode)" != adb ]]; then
      sleep 5
      continue
    fi
    v=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    if [[ "$v" == "1" ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

enter_fastboot() {
  local mode
  mode=$(phone_mode)
  case "$mode" in
    fastboot) return 0 ;;
    adb|recovery)
      "$ADB" reboot bootloader 2>/dev/null || true
      wait_mode fastboot 90 && return 0
      ;;
  esac
  log "waiting for fastboot (user may need Vol- + Power) — build keeps running"
  wait_mode fastboot 180
}

flash_rom() {
  local rom="$1"
  local twrp attempt
  twrp=$(ensure_twrp) || { log "ERROR: no TWRP img found"; return 1; }
  [[ -f "$RETRO" ]] || log "WARN: retrofit zip missing — continuing without it"

  log "FLASH start rom=$rom twrp=$twrp"
  enter_fastboot || { log "no fastboot yet — will retry next cycle (NOT stopping build)"; return 2; }
  is_rosy_fastboot || { log "ERROR: fastboot product not rosy — abort flash"; return 3; }

  "$FASTBOOT" flash recovery "$twrp" || true
  "$FASTBOOT" boot "$twrp" || "$FASTBOOT" reboot recovery || true

  if ! wait_mode recovery 90; then
    log "TWRP adb not up — retry"
    return 4
  fi

  log "TWRP up — wipe + install"
  "$ADB" shell "twrp format data" 2>/dev/null || true
  "$ADB" shell "twrp wipe cache; twrp wipe dalvik; twrp wipe system" 2>/dev/null || true

  if [[ -f "$RETRO" ]]; then
    "$ADB" push "$RETRO" /sdcard/retrofit.zip
    "$ADB" shell "twrp install /sdcard/retrofit.zip" || log "retrofit install warned"
  fi
  "$ADB" push "$rom" /sdcard/lopsidroid.zip
  "$ADB" shell "twrp install /sdcard/lopsidroid.zip" || { log "ROM install failed"; return 5; }

  echo "$rom" >"$FLASHED_MARKER"
  "$ADB" shell "twrp reboot" 2>/dev/null || "$ADB" reboot 2>/dev/null || true
  log "rebooting to system — waiting for boot"
  if boot_ok; then
    log "BOOT OK"
    write_status "SUCCESS — flashed and booted: $rom"
    return 0
  fi
  log "BOOT FAILED / timeout"
  return 6
}

fix_boot_and_reflash() {
  local rom="$1" n=0
  while [[ $n -lt $MAX_FLASH_ATTEMPTS ]]; do
    n=$((n + 1))
    log "flash/fix attempt $n/$MAX_FLASH_ATTEMPTS"
    write_status "Flashing attempt $n — phone must be on USB (build keeps running either way)"
    if flash_rom "$rom"; then
      return 0
    fi
    # bootloop / recovery: try get back to fastboot
    enter_fastboot || true
    sleep 15
  done
  write_status "FAILED after $MAX_FLASH_ATTEMPTS flash attempts — see $LOG"
  return 1
}

# --- main loop every 5 minutes ---
log "=== flash watcher start (5min). No phone ≠ stop build. ==="
write_status "Waiting for build zip + Redmi 5 USB. Build continues if phone absent."

while true; do
  # Always confirm build side is independent
  if pgrep -f 'build-dot-a17-docker' >/dev/null 2>&1; then
    log "build: still running"
  else
    log "build: not running (watchdog may restart) — flash watcher continues"
  fi

  mode=$(phone_mode)
  log "phone_mode=$mode"

  if ! rom=$(find_rom_zip); then
    log "ROM not ready yet — sleep ${INTERVAL}s (phone presence ignored)"
    write_status "Build not finished. Phone=$mode. Checking again in 5 min. Build NOT stopped."
    sleep "$INTERVAL"
    continue
  fi

  log "ROM ready: $rom"

  # Already successfully flashed this exact zip?
  if [[ -f "$FLASHED_MARKER" ]] && [[ "$(cat "$FLASHED_MARKER" 2>/dev/null)" == "$rom" ]]; then
    if [[ "$mode" == adb ]]; then
      v=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
      if [[ "$v" == "1" ]]; then
        log "already flashed and booted OK"
        write_status "DONE earlier — booted OK with $rom"
        sleep "$INTERVAL"
        continue
      fi
    fi
    log "was flashed but boot not healthy — reflash loop"
    fix_boot_and_reflash "$rom" || true
    sleep "$INTERVAL"
    continue
  fi

  if [[ "$mode" == none ]]; then
    log "ROM ready but Redmi 5 not connected — wait (NOT stopping build)"
    write_status "ROM READY: $rom — plug Redmi 5 (adb/fastboot/TWRP). Build keeps going."
    sleep "$INTERVAL"
    continue
  fi

  # Device present + ROM ready → flash
  fix_boot_and_reflash "$rom" || true
  sleep "$INTERVAL"
done
