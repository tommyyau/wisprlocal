#!/bin/bash
# Regenerates the test-only speech fixture with eSpeak NG's formant synthesizer.
# No Apple system voice or recorded speaker is used. See Fixtures/README.md for provenance.
# eSpeak NG is a developer tool only; it is never linked into or bundled with WisprLocal.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/Tests/WisprLocalCoreTests/Fixtures"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ESPEAK_BIN="${ESPEAK_NG_BIN:-espeak-ng}"
if ! command -v "$ESPEAK_BIN" >/dev/null 2>&1; then
  echo "Missing eSpeak NG. Install it with brew install espeak-ng, or set ESPEAK_NG_BIN." >&2
  exit 1
fi
ESPEAK_ARGS=()
# Optional directory containing espeak-ng-data (useful for an unpacked developer tool).
if [ -n "${ESPEAK_NG_PATH:-}" ]; then ESPEAK_ARGS+=("--path=$ESPEAK_NG_PATH"); fi
"$ESPEAK_BIN" ${ESPEAK_ARGS[@]+"${ESPEAK_ARGS[@]}"} -v en-us -s 175 -p 50 -z \
  -w "$TMP/clip05.wav" -f "$DIR/clip05.txt"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/clip05.wav" "$DIR/clip05.wav"
echo "wrote $DIR/clip05.wav"
