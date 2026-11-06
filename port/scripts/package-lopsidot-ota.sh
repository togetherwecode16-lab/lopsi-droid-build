#!/usr/bin/env bash
# Wrap a built ROM zip (or stage folder) as a LopsiDot Updates package.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$PORT/out"
STAGING="$PORT/ota/staging"
META_SRC="$PORT/vendor_dot/prebuilt/common/etc/lopsidot-ota.json"
DATE="$(date +%Y%m%d)"
NAME="LopsiDot-DotOS-A17-rosy-${DATE}"
ZIP_OUT="$OUT/${NAME}.zip"

mkdir -p "$STAGING/META-INF/com/lopsidot" "$STAGING/META-INF/com/google/android" "$OUT"

# Prefer newest target zip from AOSP out
SRC_ZIP="$(ls -t "$PORT/aosp/out/target/product/rosy/"*.zip 2>/dev/null | head -1 || true)"
if [ -n "${1:-}" ]; then
  SRC_ZIP="$1"
fi

cp -f "$META_SRC" "$STAGING/META-INF/com/lopsidot/ota.json"

# Bump incremental in metadata copy
python3 - <<PY
import json, pathlib, time
p = pathlib.Path("$STAGING/META-INF/com/lopsidot/ota.json")
d = json.loads(p.read_text())
d["incremental"] = "lopsidot-a17.${DATE}"
d["built_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
d["filename"] = "${NAME}.zip"
p.write_text(json.dumps(d, indent=2) + "\n")
PY

if [ -n "$SRC_ZIP" ] && [ -f "$SRC_ZIP" ]; then
  echo "==> Packaging existing ROM zip: $SRC_ZIP"
  # Inject LopsiDot OTA metadata into the ROM zip without recompressing the whole thing twice if possible
  cp -f "$SRC_ZIP" "$ZIP_OUT"
  (
    cd "$STAGING"
    zip -u "$ZIP_OUT" META-INF/com/lopsidot/ota.json
  )
else
  echo "==> No ROM zip yet — writing metadata-only scaffold zip for Updates app testing"
  # Minimal recovery installer that Magisk/recovery can recognize
  cat > "$STAGING/META-INF/com/google/android/updater-script" <<'EOF'
ui_print("LopsiDot DotOS A17 — metadata scaffold");
ui_print("Full system image not present in this package.");
ui_print("Build with port/scripts/build-dot-a17.sh then re-package.");
EOF
  printf '%s\n' '#!/sbin/sh' 'exit 1' > "$STAGING/META-INF/com/google/android/update-binary"
  chmod 755 "$STAGING/META-INF/com/google/android/update-binary"
  (
    cd "$STAGING"
    zip -r "$ZIP_OUT" META-INF
  )
fi

# Also drop a copy where LopsiDotUpdates / downloads expect
mkdir -p /Users/mridultyagi/Downloads/LineagePhone/downloads
cp -f "$ZIP_OUT" "/Users/mridultyagi/Downloads/LineagePhone/downloads/${NAME}.zip"
ls -lh "$ZIP_OUT"
echo "LOPSIDOT_OTA=$ZIP_OUT"
