#!/bin/bash
# Build WisprLocal.app (release) with models bundled in Contents/Resources/Models.
#   BUNDLE_MODELS="v2,ultra" (default; both bundled, only the active one is loaded) — see models_common.sh
#
# SIGNING (why it matters: macOS TCC keys Accessibility / Input Monitoring grants to the code
# signature's designated requirement; with AD-HOC signing that is the binary hash, so every
# rebuild silently loses the grants while System Settings still shows them ON). Order:
#   1. $WISPRLOCAL_SIGN_IDENTITY (name or SHA-1; "-" forces ad-hoc). Legacy alias: $SIGN_IDENTITY.
#   2. the first valid "Apple Development" identity (free via Xcode > Settings > Accounts).
#   3. "WisprLocal Local Signing" (self-signed; create once with scripts/create_signing_identity.sh).
#      It is untrusted by design, so it is looked up WITHOUT `find-identity -v`.
#   4. ad-hoc, with a loud warning.
# Hardened runtime protects library loading and ignores DYLD_* injection. Microphone capture
# requires audio-input; Foundation Models, Core ML and Accessibility / Input Monitoring event
# taps need no further entitlement. Keep timestamp=none (including Apple Development, as before):
# self-signed identities have no timestamp authority; this local build is not notarised.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
source "$HERE/models_common.sh"
OUT="$APP_DIR/build.noindex"
APP="$OUT/WisprLocal.app"
rm -rf "$OUT/WisprLite.app"  # pre-rename build product
source "$HERE/version_common.sh"
BUILD_NUM="$(date +%Y%m%d%H%M)"

cd "$APP_DIR"
echo "==> swift build -c release"
swift build --disable-automatic-resolution -c release --product WisprLocal
BIN_DIR="$(swift build --disable-automatic-resolution -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Models" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/WisprLocal" "$APP/Contents/MacOS/WisprLocal"
# SwiftPM resource bundles (FluidAudio_FluidAudio.bundle etc.); Bundle.module looks in Resources.
for b in "$BIN_DIR"/*.bundle; do
  case "$(basename "$b")" in
    *Tests*) continue ;;
    # Only LuxTTS (unused) reads FluidAudio's Bundle.module (espeak-derived lexicon) — not shipped.
    FluidAudio_FluidAudio.bundle) echo "    skip $(basename "$b") (LuxTTS-only data, unused)"; continue ;;
  esac
  cp -R "$b" "$APP/Contents/Resources/"
done

# Optional icon assets (designed separately): AppIcon.icns, MenuBarIcon{,@2x}.png and
# MenuBarIconAlert/Warm/Recording/HoldingOff{,@2x}.png (MenuBarIconState variants; matched by the MenuBarIcon* glob).
# default app icon and the SF Symbol `waveform` in the menu bar.
ICON_PLIST=""
if [ -f "$APP_DIR/Resources/AppIcon.icns" ]; then
  cp "$APP_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
  echo "    app icon: Resources/AppIcon.icns"
else
  echo "    no Resources/AppIcon.icns (skipping app icon)"
fi
MENU_ICONS=0
for f in "$APP_DIR"/Resources/MenuBarIcon*.png "$APP_DIR"/Resources/MenuBarIcon*.pdf; do
  [ -f "$f" ] || continue
  cp "$f" "$APP/Contents/Resources/"; MENU_ICONS=$((MENU_ICONS + 1))
done
echo "    menu bar icon files: $MENU_ICONS (0 = SF Symbol fallback)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.tommyyau.wisprlocal</string>
  <key>CFBundleName</key><string>WisprLocal</string>
  <key>CFBundleDisplayName</key><string>WisprLocal</string>
  <key>CFBundleExecutable</key><string>WisprLocal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  $ICON_PLIST
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>WisprLocal needs the microphone to hear you while you hold 🌐, during hands-free dictation and, if you keep the mic ready, for a short while afterwards. Everything is transcribed on this Mac and audio never leaves it.</string>
</dict>
</plist>
PLIST

echo "==> bundling models: $(model_tokens)"
FETCH_DIR="$APP_SUPPORT_MODELS"
for tok in $(model_tokens); do
  folder="$(model_folder "$tok")"
  if [ ! -d "$FETCH_DIR/$folder" ]; then
    echo "    $folder missing in $FETCH_DIR -> running fetch_models.sh"
    BUNDLE_MODELS="$BUNDLE_MODELS" "$HERE/fetch_models.sh" "$FETCH_DIR"
  fi
  "$HERE/verify_models.sh" --allow-extra "$FETCH_DIR" "$folder"
  # The manifest defines the shipped payload; download metadata stays in the cache.
  model_dest="$APP/Contents/Resources/Models/$folder"
  mkdir -p "$model_dest"
  while IFS= read -r file; do
    mkdir -p "$model_dest/$(dirname "$file")"
    cp "$FETCH_DIR/$folder/$file" "$model_dest/$file"
  done < <(awk -v model="$folder" '/^# model: / { active = ($0 == "# model: " model); next } active && /^[0-9a-f]/ { print substr($0, 67) }' "$HERE/model-manifest.sha256")
done

# STRUCTURAL: every bundled model ships its LICENSE and NOTICE (CC-BY-4.0 attribution + the
# modification notice); everything else bundled ships at least its LICENSE. Refuse to build otherwise.
echo "==> bundling licences"
MODEL_FOLDERS="$(for tok in $(model_tokens); do model_folder "$tok"; done)"
for name in $MODEL_FOLDERS $LICENSE_EXTRA; do
  if [ ! -s "$APP_DIR/Licenses/$name/LICENSE" ]; then
    echo "ERROR: missing $APP_DIR/Licenses/$name/LICENSE (required for everything bundled)" >&2; exit 1
  fi
  case " $(echo $MODEL_FOLDERS) " in *" $name "*)
    if [ ! -s "$APP_DIR/Licenses/$name/NOTICE" ]; then
      echo "ERROR: missing $APP_DIR/Licenses/$name/NOTICE (attribution required for every bundled model)" >&2; exit 1
    fi ;;
  esac
  rsync -a "$APP_DIR/Licenses/$name" "$APP/Contents/Resources/Licenses/"
  # …and beside the bundled model itself.
  if [ -d "$APP/Contents/Resources/Models/$name" ]; then
    for f in LICENSE NOTICE; do
      [ -f "$APP_DIR/Licenses/$name/$f" ] && cp "$APP_DIR/Licenses/$name/$f" "$APP/Contents/Resources/Models/$name/$f"
    done
  fi
done
# The same credits the README points to; rendered by Help › About WisprLocal › Credits….
cp "$APP_DIR/../../ACKNOWLEDGEMENTS.md" "$APP/Contents/Resources/Licenses/ACKNOWLEDGEMENTS.md"

source "$HERE/signing_common.sh"   # same identity order for the app and the receiver
resolve_sign_identity

if [ "$SIGN_IDENTITY" = "-" ]; then
  cat >&2 <<WARN

################################################################################
##  WARNING: AD-HOC CODE SIGNING
##
##  No stable signing identity found. macOS will treat THIS build as a brand-new
##  app: Accessibility and Input Monitoring permissions RESET ON EVERY REBUILD.
##  System Settings will still show WisprLocal as ON, but for the old binary,
##  and the Globe key will silently do nothing.
##
##  Fix once (creates a self-signed cert in your login keychain; run it yourself):
##      $HERE/create_signing_identity.sh
##  or add a free Apple Development cert: Xcode > Settings > Accounts.
##  Then rebuild, install, and re-grant both permissions one last time.
################################################################################

WARN
  echo "==> codesign AD-HOC"
else
  echo "==> codesign with: $SIGN_IDENTITY  [$SIGN_SOURCE]"
fi
if ! codesign --force --sign "$SIGN_IDENTITY" --identifier com.tommyyau.wisprlocal --options runtime --timestamp=none --entitlements "$APP_DIR/Resources/WisprLocal.entitlements" "$APP"; then
  echo "ERROR: codesign failed with identity $SIGN_IDENTITY ($SIGN_SOURCE)." >&2
  echo "  If a keychain prompt was denied, rerun and click Always Allow." >&2
  echo "  To build ad-hoc anyway: WISPRLOCAL_SIGN_IDENTITY=- $0" >&2
  exit 1
fi
codesign --verify --strict "$APP" && echo "    signature OK"
"$HERE/verify_bundle.sh" "$APP"
echo "    designated requirement (what TCC stores; must be identical across rebuilds):"
DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#* *designated => //p')"
echo "      ${DR:-<none printed>}"
case "$DR" in cdhash*) echo "      ^ cdhash = this exact binary: changes on every rebuild (ad-hoc)." ;; esac
du -sh "$APP"
echo "Built $APP"
