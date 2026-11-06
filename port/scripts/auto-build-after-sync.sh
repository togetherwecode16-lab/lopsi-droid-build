#!/usr/bin/env bash
# Wait for repo sync to finish, then kick the ≤40min build automatically.
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$PORT/logs/auto-build-after-sync.log"
mkdir -p "$PORT/logs"
exec >>"$LOG" 2>&1
echo "=== $(date) watcher start ==="

while pgrep -f 'main.py.*sync' >/dev/null 2>&1; do
  echo "$(date) sync still running..."
  sleep 60
done

echo "$(date) sync process gone — verifying tree"
if [ ! -f "$PORT/aosp/build/envsetup.sh" ]; then
  echo "FATAL: no envsetup.sh after sync"
  exit 1
fi
# One more repo sync -j10 to fill any holes (fast if already done)
export PATH="$HOME/bin:/opt/homebrew/bin:$PATH"
if command -v repo >/dev/null 2>&1; then
  (cd "$PORT/aosp" && repo sync -c -j10 --force-sync --no-tags --no-clone-bundle) || true
fi

echo "$(date) starting max-speed build (BUILD_MAX_MINUTES=0)"
export BUILD_MAX_MINUTES=0
"$PORT/scripts/build-dot-a17-docker.sh"
echo "$(date) build script finished rc=$?"
