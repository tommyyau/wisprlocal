#!/bin/bash
# Verify selected model folders (or every folder present) against the committed SHA-256 manifest.
# The bundle adds LICENSE/NOTICE separately; verify_bundle.sh compares those with Licenses/.
# Experimental escape hatch: WISPRLOCAL_SKIP_MODEL_VERIFY=1 (never use for a release).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ALLOW_EXTRA=0
if [ "${1:-}" = --allow-extra ]; then ALLOW_EXTRA=1; shift; fi
MODELS="${1:?usage: verify_models.sh [--allow-extra] models-dir [model-folder ...]}"
shift
fail() { echo "ERROR: model verification: $*" >&2; exit 1; }
if [ "${WISPRLOCAL_SKIP_MODEL_VERIFY:-0}" = 1 ]; then
  echo "WARNING: model integrity verification skipped (WISPRLOCAL_SKIP_MODEL_VERIFY=1)" >&2
  exit 0
fi
[ -d "$MODELS" ] || fail "missing models directory: $MODELS"
MANIFEST="$HERE/model-manifest.sha256"
[ -s "$MANIFEST" ] || fail "missing model manifest"
if [ "$ALLOW_EXTRA" = 0 ]; then
  stray="$(find "$MODELS" -mindepth 1 -maxdepth 1 ! -type d ! -type l -print)"
  [ -z "$stray" ] || fail "stray files at Models root:
$stray"
  for entry in "$MODELS"/* "$MODELS"/.[!.]* "$MODELS"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ -d "$entry" ] || fail "stray file at Models root: $entry"
  done
fi
if [ "$#" = 0 ]; then
  folders=()
  for folder in "$MODELS"/*; do
    [ -d "$folder" ] || continue
    folders+=("$(basename "$folder")")
  done
  [ "${#folders[@]}" -gt 0 ] || fail "no models present"
  set -- "${folders[@]}"
fi
for folder in "$@"; do
  case "$folder" in parakeet-tdt-0.6b-v2|parakeet-ultra|silero-vad) ;; *) fail "unsupported model: $folder" ;; esac
  [ -d "$MODELS/$folder" ] || fail "missing model: $folder"
  hashes="$(awk -v model="$folder" '/^# model: / { active = ($0 == "# model: " model); next } active && /^[0-9a-f]/ { print }' "$MANIFEST")"
  [ -n "$hashes" ] || fail "no hashes for $folder"
  # A cache model folder may itself be a symlink to a directory. Traverse its resolved
  # directory, rejecting all symlinks inside it (including broken links).
  if [ -L "$MODELS/$folder" ]; then
    echo "INFO: model folder is itself a symlink (allowed; resolves to directory): $MODELS/$folder"
  fi
  links="$(cd "$MODELS/$folder" && find . -type l -print)"
  [ -z "$links" ] || fail "symlink inside the model folder $folder (rejected):
$links"
  expected="$(printf '%s\n' "$hashes" | cut -c 67- | LC_ALL=C sort)"
  actual="$(cd "$MODELS/$folder" && find . -type f ! -path './LICENSE' ! -path './NOTICE' | sed 's#^./##' | LC_ALL=C sort)"
  payload="$(printf '%s\n' "$expected" | sed '/^LICENSE$/d; /^NOTICE$/d')"
  missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$payload" | sed '/^$/d') <(printf '%s\n' "$actual" | sed '/^$/d'))"
  extra="$(LC_ALL=C comm -13 <(printf '%s\n' "$payload" | sed '/^$/d') <(printf '%s\n' "$actual" | sed '/^$/d'))"
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    [ -z "$missing" ] || printf 'Missing files in %s:\n%s\n' "$folder" "$missing" >&2
    [ -z "$extra" ] || printf 'Extra files in %s:\n%s\n' "$folder" "$extra" >&2
    [ -z "$missing" ] || fail "file inventory differs for $folder"
    [ "$ALLOW_EXTRA" = 1 ] || fail "file inventory differs for $folder"
    echo "WARNING: extra cache files above are ignored; only manifest files ship ($folder)" >&2
  fi
  if ! out=$(cd "$MODELS/$folder" && printf '%s\n' "$hashes" | shasum -a 256 -c - 2>&1); then
    printf '%s\n' "$out" | grep -v ': OK$' >&2
    fail "SHA-256 mismatch for $folder"
  fi
  echo "OK: $folder ($(printf '%s\n' "$hashes" | wc -l | tr -d ' ') files, SHA-256 verified)"
done
