#!/bin/bash
# Populate the repo-local dev cache WisprLocal/App/.models-cache (gitignored) with the configured models.
# Copies from local spike dirs when present (no network); otherwise downloads ONCE (online).
#   BUNDLE_MODELS="v2,ultra" (default) | "v2" | "ultra"
#   WISPRLOCAL_MODEL_SOURCES="dir1:dir2" extra local source dirs to copy from (searched first); legacy alias WISPRLITE_MODEL_SOURCES
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
REPO_WL="$(cd "$APP_DIR/.." && pwd)"
source "$HERE/models_common.sh"

DEST="${1:-$MODELS_CACHE}"
mkdir -p "$DEST"
IFS=':' read -r -a SOURCES <<< "${WISPRLOCAL_MODEL_SOURCES:-${WISPRLITE_MODEL_SOURCES:-}}"
SOURCES+=("$OLD_APP_SUPPORT_MODELS" "$LEGACY_APP_SUPPORT_MODELS" "$REPO_WL/Spikes/S1b-models/Models" "$REPO_WL/Spikes/S1-parakeet/Models")

missing=()
for tok in $(model_tokens); do
  folder="$(model_folder "$tok")"
  if [ -d "$DEST/$folder" ] && [ -n "$(ls -A "$DEST/$folder" 2>/dev/null)" ]; then
    echo "ok       $tok ($folder) already in $DEST"; continue
  fi
  copied=0
  for src in "${SOURCES[@]}"; do
    [ -n "$src" ] && [ -d "$src/$folder" ] || continue
    echo "copy     $tok from $src/$folder"
    rsync -a "$src/$folder" "$DEST/"
    copied=1; break
  done
  [ "$copied" = 1 ] || missing+=("$tok")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "download ${missing[*]} (ONLINE, one-time) ..."
  (cd "$APP_DIR" && swift build -c release --product wisprlocal-fetch-models >/dev/null)
  "$APP_DIR/.build/release/wisprlocal-fetch-models" "$DEST" "${missing[@]}"
fi
"$HERE/verify_models.sh" --allow-extra "$DEST" $(for tok in $(model_tokens); do model_folder "$tok"; done)
du -sh "$DEST"/* 2>/dev/null
