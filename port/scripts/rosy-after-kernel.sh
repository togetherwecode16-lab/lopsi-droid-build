#!/bin/bash
# Wait for the in-progress kernel make, then pack and boot the fixed image only.
P=/Users/mridultyagi/Downloads/LineagePhone/port
KP=$P/kernel-port
ST=$P/logs/rosy-a17-autoloop.status
echo "$(date +%H:%M:%S) after-kernel: waiting for make" >> "$ST"
while container exec lopsi-aosp pgrep -f "make -C src O=/port/kernel-port/out" > /dev/null 2>&1; do
  sleep 20
done
IMG=$KP/out/arch/arm64/boot/Image.gz
DTB=$KP/out/arch/arm64/boot/dts/qcom/msm8953-xiaomi-rosy.dtb
if [ ! -s "$IMG" ] || [ "$IMG" -ot "$KP/out/.config" ] || ! grep -q "Image.gz is ready" "$KP/logs/build-ext4sec.log"; then
  echo "$(date +%H:%M:%S) after-kernel: build FAILED, not booting" >> "$ST"
  tail -20 "$KP/logs/build-ext4sec.log" >> "$ST"
  exit 1
fi
cat "$IMG" "$DTB" > "$KP/out/Image.gz-dtb"
"$KP/ramdisk/pack.sh" >> "$ST" 2>&1 || { echo "pack failed" >> "$ST"; exit 1; }
echo "----- $(date +%H:%M:%S) booting EXT4_FS_SECURITY kernel" >> "$ST"
ROUNDS=3 STREAM=300 exec "$P/scripts/rosy-a17-autoloop.sh"
