#!/bin/bash
# Unattended A17 GSI test loop for rosy on the 5.10 kernel (fastboot boot only,
# never flashes). Each round: wait for fastboot -> boot newest wait image ->
# save previous boot's pstore -> stream kmsg -> if still alive at the end, ask
# the gsi-init watchdog pinger to stop so the WDT resets back into fastboot.
P=/Users/mridultyagi/Downloads/LineagePhone/port
KP=$P/kernel-port
SDK=/Users/mridultyagi/Downloads/LineagePhone/.tools/android-sdk/platform-tools
FB=$SDK/fastboot
ADB=$SDK/adb
IMG=${IMG:-$KP/out/boot-rosy-gsi-wait.img}
ROUNDS=${ROUNDS:-40}
STREAM=${STREAM:-480}
STATUS=$P/logs/rosy-a17-autoloop.status

probe() { perl -e 'alarm 4; exec @ARGV' "$@" 2>/dev/null || true; }
note() { echo "$(date +%H:%M:%S) $*" | tee -a "$STATUS"; }

for round in $(seq 1 "$ROUNDS"); do
  T=$(date +%H%M%S)
  LOG=$P/logs/rosy-a17-r$round-$T.log
  note "ROUND $round waiting for fastboot"
  while :; do
    probe "$FB" devices | grep -q fastboot && break
    if probe "$ADB" devices | grep -v List | grep -q device; then
      note "ADB_UP"
      probe "$ADB" devices -l >> "$STATUS"
      perl -e 'alarm 60; exec @ARGV' "$ADB" logcat -d > "$P/logs/rosy-a17-adb-$T.logcat" 2>&1
      perl -e 'alarm 30; exec @ARGV' "$ADB" shell getprop > "$P/logs/rosy-a17-adb-$T.props" 2>&1
      sleep 120
      continue
    fi
    sleep 3
  done
  note "ROUND $round booting $(ls -l "$IMG" | awk '{print $6,$7,$8}')"
  perl -e 'alarm 90; exec @ARGV' "$FB" boot "$IMG" >> "$STATUS" 2>&1
  python3 -u "$P/scripts/rosy-serial.py" --wait 120 --timeout 15 --log "$LOG.pstore" \
    'ls -l /sys/fs/pstore' 'cat /sys/fs/pstore/console-ramoops* 2>/dev/null | tail -c 24000' \
    > /dev/null 2>&1
  # Android re-plugs the USB gadget during boot; reconnect until STREAM is up.
  END=$((SECONDS + STREAM))
  while [ $SECONDS -lt $END ]; do
    python3 -u "$P/scripts/rosy-serial-stream.py" "$LOG" $((END - SECONDS)) >> "$STATUS" 2>&1
    probe "$FB" devices | grep -q fastboot && break
    sleep 5
  done
  # No self-reboot: a kernel reboot lands in the Mi bootloop, not fastboot.
  ls /dev/cu.usbmodem* > /dev/null 2>&1 && note "ROUND $round still up after stream; leaving it running"
  {
    echo "=== ROUND $round key lines ($LOG)"
    tr -d '\r' < "$LOG" | sed -E 's/^[0-9]+,[0-9]+,([0-9]+),[^;]*;/[\1] /' |
      grep -avE "^ (SUBSYSTEM|DEVICE)=" |
      grep -aE "prep:|gsi-init|init: |panic|Kernel panic|Unable|Oops" | tail -60
  } >> "$STATUS"
  note "ROUND $round end"
done
note "LOOP DONE"
