#!/bin/bash
# Inspect the assembled and signed app/receiver: retained credits must match the source,
# supported models must carry attribution, and unused native/TTS/test assets must be absent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
APP="${1:?usage: verify_bundle.sh path/to/app}"
RES="$APP/Contents/Resources"
LIC="$RES/Licenses"
fail() { echo "ERROR: bundle verification: $*" >&2; exit 1; }
same() { cmp -s "$1" "$2" || fail "missing or changed credit: $2"; }

same "$APP_DIR/Licenses/FluidAudio/LICENSE" "$LIC/FluidAudio/LICENSE"
same "$APP_DIR/Licenses/FluidAudio/NOTICE" "$LIC/FluidAudio/NOTICE"
for notice in JapaneseG2P-LICENSE.md KokoroAneSpanishFrenchG2P-LICENSE.md fastcluster-LICENSE.md vbx-LICENSE.md; do
  same "$APP_DIR/Licenses/FluidAudio/ThirdPartyLicenses/$notice" "$LIC/FluidAudio/ThirdPartyLicenses/$notice"
done
[ "$(find "$LIC/FluidAudio/ThirdPartyLicenses" -type f | wc -l | tr -d ' ')" = 4 ] || fail "unexpected library notice inventory"
ACK="$LIC/ACKNOWLEDGEMENTS.md"
[ -f "$ACK" ] || ACK="$RES/ACKNOWLEDGEMENTS.md"
same "$APP_DIR/../../ACKNOWLEDGEMENTS.md" "$ACK"

for model in "$RES/Models"/*; do
  [ -d "$model" ] || continue
  name="$(basename "$model")"
  case "$name" in parakeet-tdt-0.6b-v2|parakeet-ultra|silero-vad) ;; *) fail "unsupported bundled model: $name" ;; esac
  for notice in LICENSE NOTICE; do
    same "$APP_DIR/Licenses/$name/$notice" "$LIC/$name/$notice"
    same "$APP_DIR/Licenses/$name/$notice" "$model/$notice"
  done
done

# Bundles always require exact model inventory; cache-only extras must never ship.
if [ -d "$RES/Models" ]; then
  "$HERE/verify_models.sh" "$RES/Models"
fi

UNUSED="$(find "$RES" \( -name '*NemoTextProcessing*' -o -name 'FluidAudio_FluidAudio.bundle' -o -name '*Tests*.bundle' -o -name '*.xctest' \) -print -quit)"
[ -z "$UNUSED" ] || fail "unused dependency or test resource: $UNUSED"
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || fail "missing version"
echo "    version: $VERSION (build $BUILD)"
codesign --verify --strict "$APP" || fail "invalid signature"
FLAGS="$(codesign -d --verbose=2 "$APP" 2>&1)"
printf '%s\n' "$FLAGS" | grep -Eq 'flags=.*\(.*runtime.*\)' || fail "hardened runtime missing"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
mkdir -p "$APP_DIR/build.noindex"
SYMBOLS="$(mktemp "$APP_DIR/build.noindex/bundle-symbols.XXXXXX")"
trap 'rm -f "$SYMBOLS" "$SYMBOLS.entitlements"' EXIT
nm "$APP/Contents/MacOS/$EXECUTABLE" > "$SYMBOLS"
if grep -Eq '_nemo_|text_processing_rs|rustfst' "$SYMBOLS"; then
  fail "unused native text-normalization engine is linked"
fi
if [ "$EXECUTABLE" = WisprLocal ]; then
  MIC="$(/usr/libexec/PlistBuddy -c 'Print NSMicrophoneUsageDescription' "$PLIST" 2>/dev/null)" || fail "missing NSMicrophoneUsageDescription"
  [ -n "$MIC" ] || fail "empty NSMicrophoneUsageDescription"
  ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" || fail "cannot read entitlements"
  printf '%s\n' "$ENTITLEMENTS" > "$SYMBOLS.entitlements"
  AUDIO="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$SYMBOLS.entitlements" 2>/dev/null)" || fail "missing audio-input entitlement"
  [ "$AUDIO" = true ] || fail "audio-input entitlement is not true"
  grep -Eq 'FluidAudio.*AsrManager' "$SYMBOLS" || fail "FluidAudio speech-recognition implementation missing"
  grep -Eq 'FluidAudio.*VadManager' "$SYMBOLS" || fail "FluidAudio speech-detection implementation missing"
fi
echo "OK: $(basename "$APP") retains FluidAudio credits; model notices match; NemoTextProcessing and unused resources excluded."
