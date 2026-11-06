#!/usr/bin/env bash
# Install big warnings + macOS immutable flags on marker files so casual rm is harder.
# Does NOT lock the folders themselves (builds must write into them).
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"

WARN_TEXT='!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
STOP. DO NOT DELETE THIS FOLDER.

This is NOT random cache. This is NOT safe to clear.
Deleting this can WASTE HOURS OR DAYS of compile work.

Protected paths:
  - port/ccache          (compiler cache — daily 20-30min builds)
  - port/out             (flashable zips / build logs)
  - port/aosp/out        (full Android build tree — THE expensive one)

If you delete these you will re-do the entire first compile from scratch.

To remove ONLY if you truly mean it (you almost never do):
  chflags -R nouchg "'"$PORT"'/ccache" "'"$PORT"'/out" "'"$PORT"'/aosp/out"
  # then rm — but expect hours/days to rebuild

Daily builds:  ./port/scripts/build-daily.sh
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
'

protect_dir() {
  local d="$1"
  mkdir -p "$d"
  local f="$d/!!!_DO_NOT_DELETE_THIS_FOLDER_!!!.txt"
  local f2="$d/DO_NOT_DELETE_NOT_RANDOM_CACHE_HOURS_OF_WORK.txt"
  for x in "$f" "$f2" "$d/000_DO_NOT_DELETE_WASTES_DAYS_OF_WORK"; do
    chflags nouchg "$x" 2>/dev/null || true
  done
  printf '%s\n' "$WARN_TEXT" >"$f"
  printf '%s\n' "$WARN_TEXT" >"$f2"
  touch "$d/000_DO_NOT_DELETE_WASTES_DAYS_OF_WORK"
  chflags uchg "$f" "$f2" "$d/000_DO_NOT_DELETE_WASTES_DAYS_OF_WORK" 2>/dev/null || true
  chmod 444 "$f" "$f2" 2>/dev/null || true
  # Block deleting the folder itself in Finder/rm (files inside still writable)
  chmod +a "everyone deny delete" "$d" 2>/dev/null || true
}

protect_dir "$PORT/ccache"
protect_dir "$PORT/out"
protect_dir "$PORT/aosp/out"

# Parent-level scream files (easy to see in Finder)
for parent in "$PORT" "$PORT/aosp"; do
  f="$parent/!!!_OUT_AND_CCACHE_DO_NOT_DELETE_!!!.txt"
  printf '%s\n' "$WARN_TEXT" >"$f"
  chflags uchg "$f" 2>/dev/null || true
  chmod 444 "$f" 2>/dev/null || true
done

# Finder comment / baner via .metadata_never_index style + Desktop Services
# Hidden but visible name:
for d in "$PORT/ccache" "$PORT/out" "$PORT/aosp/out"; do
  mkdir -p "$d"
  # Empty file with a name Finder sorts first
  touch "$d/000_DO_NOT_DELETE_WASTES_DAYS_OF_WORK"
  chflags uchg "$d/000_DO_NOT_DELETE_WASTES_DAYS_OF_WORK" 2>/dev/null || true
done

echo "PROTECT_OK: warnings installed under ccache, out, aosp/out"
ls -la "$PORT/ccache" "$PORT/out" 2>/dev/null | head -20
