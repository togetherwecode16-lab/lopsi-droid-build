#!/usr/bin/env bash
# Overlay vendor + rosy trees WITHOUT blowing mtimes (critical for 20-30min daily builds).
# Never rm -rf destinations — that forces a full rebuild every run.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
AOSP="${AOSP_DIR:-$PORT/aosp}"
ROOT="$(cd "$PORT/.." && pwd)"

mkdir -p "$AOSP/vendor" "$AOSP/device/xiaomi" "$AOSP/kernel/xiaomi" "$AOSP/vendor/xiaomi"

# Soong invalidates its graph when an Android.bp mtime changes.  Preserve
# unchanged files exactly: this script runs before every retry.
sync_file_if_changed() {
  local src="$1" dst="$2"
  if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
  fi
}

# rsync -a preserves times; only content changes invalidate ninja
rsync -a --delete --exclude .git "$PORT/vendor_dot/" "$AOSP/vendor/dot/"

if [ -d "$PORT/trees/device_xiaomi_rosy" ]; then
  rsync -a --delete --exclude .git "$PORT/trees/device_xiaomi_rosy/" "$AOSP/device/xiaomi/rosy/"
fi
# libhwbinder must be in the root namespace (device/xiaomi/rosy is a soong_namespace).
if [ -f "$PORT/trees/device_lopsi_hwbinder/Android.bp" ]; then
  mkdir -p "$AOSP/device/lopsi/hwbinder"
  rsync -a --delete --exclude .git "$PORT/trees/device_lopsi_hwbinder/" "$AOSP/device/lopsi/hwbinder/"
fi
if [ -f "$PORT/trees/kernel_xiaomi_rosy/Makefile" ]; then
  rsync -a --delete --exclude .git "$PORT/trees/kernel_xiaomi_rosy/" "$AOSP/kernel/xiaomi/rosy/"
fi
if [ -f "$PORT/trees/vendor_xiaomi_rosy/rosy-vendor.mk" ]; then
  rsync -a --delete --exclude .git "$PORT/trees/vendor_xiaomi_rosy/" "$AOSP/vendor/xiaomi/rosy/"
fi

# Stub missing CAF soong namespaces (not synced; qcom-caf used to import them)
for stub in \
  vendor/qcom/opensource/commonsys-intf/display \
  vendor/qcom/opensource/display
do
  mkdir -p "$AOSP/$stub"
  if [ ! -f "$AOSP/$stub/Android.bp" ]; then
    printf '%s\n' '// LopsiDroid stub soong_namespace' 'soong_namespace {' '}' >"$AOSP/$stub/Android.bp"
  fi
done

chmod 755 "$AOSP/vendor/dot/prebuilt/common/bin/"*.sh 2>/dev/null || true

sync_apk() {
  local src="$1"
  local dest_dir="$2"
  local dest_name="$3"
  if [ -f "$src" ]; then
    mkdir -p "$dest_dir"
    if [ ! -f "$dest_dir/$dest_name" ] || [ "$src" -nt "$dest_dir/$dest_name" ]; then
      cp -f "$src" "$dest_dir/$dest_name"
      echo "APK_SYNC $dest_name"
    fi
  fi
}

# System apps baked into the ROM
sync_apk \
  "$ROOT/LopsiDotUpdates/app/build/outputs/apk/debug/app-debug.apk" \
  "$AOSP/vendor/dot/prebuilt/common/priv-app/LopsiDotUpdates" \
  "LopsiDotUpdates.apk"

sync_apk \
  "$ROOT/LopsiSetup/app/build/outputs/apk/debug/app-debug.apk" \
  "$AOSP/vendor/dot/prebuilt/common/priv-app/LopsiSetup" \
  "LopsiSetup.apk"

sync_apk \
  "$ROOT/LopsiLauncher/app/build/outputs/apk/debug/app-debug.apk" \
  "$AOSP/vendor/dot/prebuilt/common/priv-app/LopsiLauncher" \
  "LopsiLauncher.apk"

# Keep copies under port/vendor_dot so rsync to aosp stays authoritative
sync_apk \
  "$ROOT/LopsiDotUpdates/app/build/outputs/apk/debug/app-debug.apk" \
  "$PORT/vendor_dot/prebuilt/common/priv-app/LopsiDotUpdates" \
  "LopsiDotUpdates.apk"
sync_apk \
  "$ROOT/LopsiSetup/app/build/outputs/apk/debug/app-debug.apk" \
  "$PORT/vendor_dot/prebuilt/common/priv-app/LopsiSetup" \
  "LopsiSetup.apk"
sync_apk \
  "$ROOT/LopsiLauncher/app/build/outputs/apk/debug/app-debug.apk" \
  "$PORT/vendor_dot/prebuilt/common/priv-app/LopsiLauncher" \
  "LopsiLauncher.apk"

echo "OVERLAY_OK (incremental) -> $AOSP"

# LopsiDroid: soong test-harness stubs (CTS/VTS/art gtest parked)
# DISABLED: real cts/, platform_testing/, frameworks/ modules ARE present in this
# checkout, so re-adding these stub definitions only creates duplicate-module
# soong errors. Do not re-enable without parking the real definitions first.
# DISABLED: mkdir -p "$AOSP/art/art_gtest_defaults_stub"
# DISABLED: if [ -f "$PORT/trees/stubs/test_defaults_stub.bp" ]; then
# DISABLED:   sync_file_if_changed "$PORT/trees/stubs/test_defaults_stub.bp" "$AOSP/art/art_gtest_defaults_stub/Android.bp"

# AOSP's DeviceAsWebcam test zip declares tests/* but this source checkout
# omits that directory. Keep the production service enabled while satisfying
# the optional test-only genrule.
if [ -f "$PORT/trees/stubs/device_as_webcam_test_placeholder.txt" ]; then
  sync_file_if_changed "$PORT/trees/stubs/device_as_webcam_test_placeholder.txt" "$AOSP/packages/services/DeviceAsWebcam/tests/lopsidroid-placeholder.txt"
fi

# This checkout omits libxml2's fuzz corpus. It is only used by the optional
# host fuzz target; retain libxml2 itself and provide one harmless fixture.
if [ -f "$PORT/trees/stubs/libxml2_schema_placeholder.xsd" ]; then
  sync_file_if_changed "$PORT/trees/stubs/libxml2_schema_placeholder.xsd" "$AOSP/external/libxml2/test/schemas/lopsidroid-placeholder.xsd"
fi

# Global host/test stubs (must live outside device soong_namespace)
# DISABLED: same reason as art_gtest_defaults_stub above — the real definitions
# (cts/, tools/tradefederation/, platform_testing/, frameworks/) exist here.
# DISABLED: if [ -d "$PORT/trees/stubs/lopsidroid_host_stubs" ]; then
# DISABLED:   mkdir -p "$AOSP/art/lopsidroid_host_stubs"
# DISABLED:   rsync -a --delete --exclude .git "$PORT/trees/stubs/lopsidroid_host_stubs/" "$AOSP/art/lopsidroid_host_stubs/"


# Sticky init patch — drop microdroid neverallow modules (rosy)
if [ -f "$PORT/trees/patches/system_core_init_Android.bp" ]; then
  sync_file_if_changed "$PORT/trees/patches/system_core_init_Android.bp" "$AOSP/system/core/init/Android.bp"
  echo "INIT_MICROID_STRIPPED"
fi


if [ -f "$PORT/trees/patches/external_cronet_Android.bp" ]; then
  sync_file_if_changed "$PORT/trees/patches/external_cronet_Android.bp" "$AOSP/external/cronet/Android.bp"
fi

if [ -f "$PORT/trees/patches/build_make_core_envsetup.mk" ]; then
  sync_file_if_changed "$PORT/trees/patches/build_make_core_envsetup.mk" "$AOSP/build/make/core/envsetup.mk"
fi

if [ -f "$PORT/trees/patches/build_soong_java_droiddoc.go" ]; then
  sync_file_if_changed "$PORT/trees/patches/build_soong_java_droiddoc.go" "$AOSP/build/soong/java/droiddoc.go"
fi

if [ -f "$PORT/trees/patches/build_soong_java_ravenwood.go" ]; then
  sync_file_if_changed "$PORT/trees/patches/build_soong_java_ravenwood.go" "$AOSP/build/soong/java/ravenwood.go"
fi

if [ -f "$PORT/trees/patches/build_blueprint_bootstrap_command.go" ]; then
  sync_file_if_changed "$PORT/trees/patches/build_blueprint_bootstrap_command.go" "$AOSP/build/blueprint/bootstrap/command.go"
fi

# arm64 host: compiler toolchains only ship linux-x86, run them via Rosetta
for f in android/config.go android/paths.go cc/config/global.go rust/config/global.go; do
  p="$PORT/trees/patches/build_soong_$(echo "$f" | tr '/' '_')"
  if [ -f "$p" ]; then
    sync_file_if_changed "$p" "$AOSP/build/soong/$f"
  fi
done
if [ -f "$PORT/trees/patches/hardware_qcom_wlan_legacy_qcwcn_config_Android.mk" ]; then
  sync_file_if_changed "$PORT/trees/patches/hardware_qcom_wlan_legacy_qcwcn_config_Android.mk" "$AOSP/hardware/qcom/wlan/legacy/qcwcn/config/Android.mk"
fi
if [ -f "$PORT/trees/patches/build_make_core_Makefile" ]; then
  sync_file_if_changed "$PORT/trees/patches/build_make_core_Makefile" "$AOSP/build/make/core/Makefile"
fi
if [ -f "$PORT/trees/patches/build_make_core_clang_HOST_arm64.mk" ]; then
  sync_file_if_changed "$PORT/trees/patches/build_make_core_clang_HOST_arm64.mk" "$AOSP/build/make/core/clang/HOST_arm64.mk"
fi
if [ -d "$AOSP/prebuilts/cipd/linux-x86" ] && [ ! -e "$AOSP/prebuilts/cipd/linux-arm64" ]; then
  ln -sfn linux-x86 "$AOSP/prebuilts/cipd/linux-arm64"
fi
for jdk in "$AOSP"/prebuilts/jdk/*/; do
  if [ -d "${jdk}linux-x86" ] && [ ! -e "${jdk}linux-arm64" ]; then
    ln -s linux-x86 "${jdk}linux-arm64"
  fi
done

# Partial system/chre checkout: keep the flag libraries frameworks/base needs
if [ -f "$PORT/trees/patches/system_chre_Android.bp" ]; then
  sync_file_if_changed "$PORT/trees/patches/system_chre_Android.bp" "$AOSP/system/chre/Android.bp"
fi

if [ -f "$PORT/trees/parks/FIND_IGNORE_DIRS.txt" ]; then
  while IFS= read -r d || [ -n "$d" ]; do
    [ -z "$d" ] && continue
    [[ "$d" =~ ^# ]] && continue
    [ -d "$AOSP/$d" ] && [ ! -f "$AOSP/$d/.find-ignore" ] && : > "$AOSP/$d/.find-ignore"
  done < "$PORT/trees/parks/FIND_IGNORE_DIRS.txt"
  echo "FIND_IGNORE_APPLIED"
fi

# Force-park host/virt BPs so retries don't revive soong blockers (deadline day)
if [ -f "$PORT/trees/parks/FORCE_PARK_BPS.txt" ]; then
  while IFS= read -r bp || [ -n "$bp" ]; do
    [ -z "$bp" ] && continue
    [[ "$bp" =~ ^# ]] && continue
    f="$AOSP/$bp"
    [ -f "$f" ] || continue
    if ! grep -q '^// parked' "$f" 2>/dev/null; then
      mkdir -p "$PORT/parked-trees"
      cp "$f" "$PORT/parked-trees/${bp//\//_}" 2>/dev/null || true
    fi
    # any parked marker counts; rewriting bumps mtime and forces a full soong re-analysis
    if ! grep -q '^// parked' "$f" 2>/dev/null; then
      printf '// parked — force park (rosy otapackage deadline)\n' > "$f"
    fi
  done < "$PORT/trees/parks/FORCE_PARK_BPS.txt"
  # also park Virtualization guest tree BPs
  find "$AOSP/packages/modules/Virtualization/guest" -name Android.bp 2>/dev/null | while read -r f; do
    if ! grep -q '^// parked' "$f" 2>/dev/null; then
      printf '// parked — virt guest (rosy)\n' > "$f"
    fi
  done
  echo "FORCE_PARKS_APPLIED"
fi
