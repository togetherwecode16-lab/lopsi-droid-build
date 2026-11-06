#!/bin/bash
# Follow the newest rosy A17 boot log and print milestones / failures.
L=/Users/mridultyagi/Downloads/LineagePhone/port/logs
PAT='prep: (.*ro.vndk|/system/apex|/metadata)|mount_all.*took|enforce file reset|apexd-bootstrap: (Activated|Failed)|linkerconfig: (Check failed|Unable)|starting service .(zygote|surfaceflinger|system_server|bootanim|adbd|servicemanager)|servicemanager.ready|sys.boot_completed|Boot is finished|shutdown_command|Reboot start|FATAL|Fatal signal|pinger:|Kernel panic'
cur=
while :; do
  new=$(ls -t "$L"/rosy-a17-r1-*.log 2>/dev/null | head -1)
  if [ -n "$new" ] && [ "$new" != "$cur" ]; then
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    cur=$new
    echo "WATCH new boot log ${cur##*/}"
    tail -n +1 -F "$cur" 2>/dev/null | grep --line-buffered -E "$PAT" &
    pid=$!
  fi
  if ! fastboot devices | grep -q . ; then :; else
    [ -z "$fb" ] && echo "WATCH $(date +%T) phone in fastboot"; fb=1; sleep 10; continue
  fi
  fb=
  sleep 10
done
