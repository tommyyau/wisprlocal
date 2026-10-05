#!/bin/bash
# Build WisprLocalReceiver.app (release) into build.noindex/ — the tiny menu-bar helper that runs
# on the REMOTE Mac (see WisprLocal/docs/REMOTE.md). No models are bundled.
# Signed with the same identity order as build_app.sh (scripts/signing_common.sh), so the remote
# Mac's Accessibility grant survives rebuilds when a stable identity exists.
# This script only builds; it never installs or launches anything.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
OUT="$APP_DIR/build.noindex"
APP="$OUT/WisprLocalReceiver.app"
BUNDLE_ID="com.tommyyau.wisprlocal.receiver"
source "$HERE/version_common.sh"
BUILD_NUM="$(date +%Y%m%d%H%M)"

cd "$APP_DIR"
echo "==> swift build --disable-automatic-resolution -c release --product WisprLocalReceiver"
swift build --disable-automatic-resolution -c release --product WisprLocalReceiver
BIN_DIR="$(swift build --disable-automatic-resolution -c release --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/WisprLocalReceiver" "$APP/Contents/MacOS/WisprLocalReceiver"
# REL-3 (STRUCTURAL): the receiver links WisprLocalCore -> FluidAudio (Apache-2.0) and its
# fastcluster (BSD-2) code: ship their licence texts.
if [ ! -s "$APP_DIR/Licenses/FluidAudio/LICENSE" ] || [ ! -d "$APP_DIR/Licenses/FluidAudio/ThirdPartyLicenses" ]; then
  echo "ERROR: missing $APP_DIR/Licenses/FluidAudio/{LICENSE,ThirdPartyLicenses} (required for the receiver)" >&2; exit 1
fi
mkdir -p "$APP/Contents/Resources/Licenses"
rsync -a "$APP_DIR/Licenses/FluidAudio" "$APP/Contents/Resources/Licenses/"
cp "$APP_DIR/../../ACKNOWLEDGEMENTS.md" "$APP/Contents/Resources/ACKNOWLEDGEMENTS.md"
cp "$APP_DIR/../../LICENSE" "$APP/Contents/Resources/LICENSE"
ICON_PLIST=""
if [ -f "$APP_DIR/Resources/AppIcon.icns" ]; then
  cp "$APP_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_PLIST="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>WisprLocal Receiver</string>
  <key>CFBundleDisplayName</key><string>WisprLocal Receiver</string>
  <key>CFBundleExecutable</key><string>WisprLocalReceiver</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  $ICON_PLIST
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Hardened runtime needs no entitlement for the receiver (no microphone, only event taps).
source "$HERE/signing_common.sh"
resolve_sign_identity
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "WARNING: ad-hoc signing — the remote Mac's Accessibility grant will reset on every rebuild." >&2
  echo "         Fix once with $HERE/create_signing_identity.sh (see build_app.sh)." >&2
  echo "==> codesign AD-HOC"
else
  echo "==> codesign with: $SIGN_IDENTITY  [$SIGN_SOURCE]"
fi
if ! codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime --timestamp=none "$APP"; then
  echo "ERROR: codesign failed with identity $SIGN_IDENTITY ($SIGN_SOURCE)." >&2
  echo "  To build ad-hoc anyway: WISPRLOCAL_SIGN_IDENTITY=- $0" >&2
  exit 1
fi
codesign --verify --strict "$APP" && echo "    signature OK"
"$HERE/verify_bundle.sh" "$APP"
DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#* *designated => //p')"
echo "    designated requirement: ${DR:-<none printed>}"
du -sh "$APP"
echo "Built $APP"
