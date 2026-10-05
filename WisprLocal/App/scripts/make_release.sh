#!/bin/bash
# Build the WisprLocal release artefacts locally. Publishes NOTHING (no git push, no GitHub release).
#
#   scripts/make_release.sh                 # VERSION comes from App/VERSION
#   Update App/VERSION before making a new release.
#
# Output (WisprLocal/App/build.noindex/release/):
#   WisprLocal-<version>.dmg            drag-to-Applications disk image (app + /Applications link,
#                                       branded background, icon positions)
#   WisprLocalReceiver-<version>.zip    the remote-Mac receiver, if the target exists in Package.swift
#   SHA256SUMS.txt                      shasum -a 256 of every artefact
#
# SIGNING GATE: v1 is not notarised and has no Developer ID. Both apps must use the same
# non-ad-hoc identity (Apple Development or self-signed, for example "WisprLocal Local Signing")
# so updates preserve their designated requirements and users keep their privacy grants.
# WISPRLOCAL_ALLOW_ADHOC=1 permits a local dry run, explicitly labelled NOT A RELEASE.
#
# Size: the DMG is about the size of Resources/Models (about 1.1 GB with both models).
# GitHub release assets may be up to 2 GiB each, so this fits.
#
# Dependencies: Xcode command-line tools only (hdiutil, codesign, osascript, tiffutil, swift).
# create-dmg is NOT used even if installed: the hdiutil path below is the one that is tested.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
OUT="$APP_DIR/build.noindex"
REL="$OUT/release"
WORK="$OUT/release-work"
source "$HERE/version_common.sh"
EXPECTED_VERSION="$RELEASE_VERSION"
[ "$VERSION" = "$RELEASE_VERSION" ] || { echo "ERROR: release VERSION must equal App/VERSION ($RELEASE_VERSION)" >&2; exit 1; }
[ "${WISPRLOCAL_SKIP_MODEL_VERIFY:-0}" != 1 ] || { echo "ERROR: model verification cannot be skipped for a release" >&2; exit 1; }
RECEIVER_ID="com.tommyyau.wisprlocal.receiver"
source "$HERE/signing_common.sh"
resolve_sign_identity
SUFFIX=""
ADHOC_DRYRUN=0
if [ "$SIGN_IDENTITY" = "-" ]; then
  [ "${WISPRLOCAL_ALLOW_ADHOC:-0}" = 1 ] || { echo "ERROR: both release apps require the same non-ad-hoc signing identity" >&2; exit 1; }
  ADHOC_DRYRUN=1
  SUFFIX="-adhoc-dryrun"
  echo "WARNING: AD-HOC DRY RUN — NOT A RELEASE. DR and certificate identity gates are explicitly skipped." >&2
fi
# Resolve once and pass the same identity to every build; never fall back for the receiver.
export WISPRLOCAL_SIGN_IDENTITY="$SIGN_IDENTITY"

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
echo "==> 1/6 build WisprLocal.app (VERSION=$EXPECTED_VERSION via build_app.sh)"
# Both builders read App/VERSION; releases refuse experimental overrides.
VERSION="$EXPECTED_VERSION" "$HERE/build_app.sh"
APP="$OUT/WisprLocal.app"
[ -d "$APP" ] || die "build_app.sh did not produce $APP"

PLIST="$APP/Contents/Info.plist"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
[ "$APP_VERSION" = "$EXPECTED_VERSION" ] || \
  die "Info.plist CFBundleShortVersionString is '$APP_VERSION', expected '$EXPECTED_VERSION'"
echo "    version (from Info.plist): $APP_VERSION"

# ---------------------------------------------------------------------------------------------
echo "==> 2/6 signing gate"
DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#* *designated => //p')"
echo "    designated requirement: ${DR:-<none>}"
if [ "$ADHOC_DRYRUN" = 1 ]; then
  echo "WARNING: NOT A RELEASE: skipping main app non-ad-hoc DR and certificate checks" >&2
else
  case "$DR" in cdhash*|"") die "release app must have a non-ad-hoc designated requirement" ;; esac
  # Compare leaf certificates, since each app has its own bundle identifier in its DR.
  APP_CERT="$(certificate_hash main "$APP")"
fi
"$HERE/verify_bundle.sh" "$APP"

rm -rf "$WORK"; mkdir -p "$WORK" "$REL"
DMG="$REL/WisprLocal-$APP_VERSION$SUFFIX.dmg"
ZIP="$REL/WisprLocalReceiver-$APP_VERSION$SUFFIX.zip"
rm -f "$DMG" "$ZIP" "$REL/SHA256SUMS$SUFFIX.txt"

# ---------------------------------------------------------------------------------------------
echo "==> 3/6 WisprLocalReceiver.app"
ARTEFACTS=("$DMG")
if grep -q '"WisprLocalReceiver"' "$APP_DIR/Package.swift" && [ -d "$APP_DIR/Sources/WisprLocalReceiver" ]; then
  (cd "$APP_DIR" && swift build --disable-automatic-resolution -c release --product WisprLocalReceiver)
  BIN_DIR="$(cd "$APP_DIR" && swift build --disable-automatic-resolution -c release --show-bin-path)"
  RAPP="$WORK/WisprLocalReceiver.app"
  mkdir -p "$RAPP/Contents/MacOS" "$RAPP/Contents/Resources"
  cp "$BIN_DIR/WisprLocalReceiver" "$RAPP/Contents/MacOS/WisprLocalReceiver"
  [ -f "$APP_DIR/Resources/AppIcon.icns" ] && cp "$APP_DIR/Resources/AppIcon.icns" "$RAPP/Contents/Resources/AppIcon.icns"
  cp "$APP_DIR/../../ACKNOWLEDGEMENTS.md" "$RAPP/Contents/Resources/ACKNOWLEDGEMENTS.md"
  cp "$APP_DIR/../../LICENSE" "$RAPP/Contents/Resources/LICENSE"
  # REL-3 (STRUCTURAL): the receiver links WisprLocalCore -> FluidAudio (Apache-2.0) and its
  # fastcluster (BSD-2) code: ship their licence texts.
  if [ ! -s "$APP_DIR/Licenses/FluidAudio/LICENSE" ] || [ ! -d "$APP_DIR/Licenses/FluidAudio/ThirdPartyLicenses" ]; then
    echo "ERROR: missing $APP_DIR/Licenses/FluidAudio/{LICENSE,ThirdPartyLicenses} (required for the receiver)" >&2; exit 1
  fi
  mkdir -p "$RAPP/Contents/Resources/Licenses"
  rsync -a "$APP_DIR/Licenses/FluidAudio" "$RAPP/Contents/Resources/Licenses/"
  cat > "$RAPP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$RECEIVER_ID</string>
  <key>CFBundleName</key><string>WisprLocal Receiver</string>
  <key>CFBundleDisplayName</key><string>WisprLocal Receiver</string>
  <key>CFBundleExecutable</key><string>WisprLocalReceiver</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>WisprLocal Receiver listens only on this Mac's Tailscale address for text sent by your paired WisprLocal.</string>
</dict>
</plist>
PLIST
  # No microphone entitlement is needed by the hardened receiver.
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$RECEIVER_ID" --options runtime --timestamp=none "$RAPP"
  codesign --verify --strict "$RAPP"
  RDR="$(codesign -d -r- "$RAPP" 2>/dev/null | sed -n 's/^#* *designated => //p')"
  if [ "$ADHOC_DRYRUN" = 1 ]; then
    echo "WARNING: NOT A RELEASE: skipping receiver non-ad-hoc DR and certificate checks" >&2
  else
    case "$RDR" in cdhash*|"") die "receiver must not be ad-hoc signed" ;; esac
    [ "$(certificate_hash receiver "$RAPP")" = "$APP_CERT" ] || die "app and receiver signing identities differ"
  fi
  "$HERE/verify_bundle.sh" "$RAPP"
  echo "    receiver DR: $(codesign -d -r- "$RAPP" 2>/dev/null | sed -n 's/^#* *designated => //p')"
  ditto -c -k --sequesterRsrc --keepParent "$RAPP" "$ZIP"
  ARTEFACTS+=("$ZIP")
else
  echo "    no WisprLocalReceiver target: skipping the receiver zip"
fi

# ---------------------------------------------------------------------------------------------
echo "==> 4/6 DMG background (orb colours)"
BG_SWIFT="$WORK/make_bg.swift"
cat > "$BG_SWIFT" <<'SWIFT'
import AppKit
// 660x400 pt drag-to-Applications background in the orb palette (Theme.swift / icon-B).
let args = CommandLine.arguments
let scale = CGFloat(Double(args[2])!)
let W = 660 * scale, H = 400 * scale
func c(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)
// Indigo base gradient (0x241A5C -> 0x120D2E), top to bottom (CG origin is bottom-left).
let base = CGGradient(colorsSpace: cs, colors: [c(0x241A5C), c(0x120D2E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 400), end: CGPoint(x: 0, y: 0), options: [])
// Soft violet + mint glows behind the two icon slots.
for (x, col) in [(165.0, c(0x6B5BD6, 0.35)), (495.0, c(0x7CF5D4, 0.16))] {
  let g = CGGradient(colorsSpace: cs, colors: [col, c(0x120D2E, 0)] as CFArray, locations: [0, 1])!
  ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: 210), startRadius: 0,
                         endCenter: CGPoint(x: x, y: 210), endRadius: 130, options: [])
}
// Label plates: Finder draws icon names in black (light mode) or white (dark mode) and ignores the
// background, so each name sits on a mid-tone plate (~4.5:1 contrast for both).
ctx.setFillColor(c(0x7D74B8, 0.95))
for x in [165.0, 495.0] {
  ctx.addPath(CGPath(roundedRect: CGRect(x: x - 66, y: 400 - 280, width: 132, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
  ctx.fillPath()
}
// Arrow from the app slot to the Applications slot.
ctx.setStrokeColor(c(0x7CF5D4, 0.9)); ctx.setLineWidth(4); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 262, y: 210)); ctx.addLine(to: CGPoint(x: 392, y: 210)); ctx.strokePath()
ctx.move(to: CGPoint(x: 376, y: 224)); ctx.addLine(to: CGPoint(x: 394, y: 210)); ctx.addLine(to: CGPoint(x: 376, y: 196)); ctx.strokePath()
// Text.
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
func text(_ s: String, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight, _ col: NSColor) {
  let p = NSMutableParagraphStyle(); p.alignment = .center
  let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                          .foregroundColor: col, .paragraphStyle: p]
  NSAttributedString(string: s, attributes: a).draw(in: CGRect(x: 0, y: y, width: 660, height: size + 8))
}
text("Drag WisprLocal to Applications", 330, 20, .semibold, NSColor(cgColor: c(0xFFFFFF, 0.95))!)
text("First launch: System Settings › Privacy & Security › Open Anyway", 62, 12.5, .medium, NSColor(cgColor: c(0x7CF5D4, 0.95))!)
text("Fast, private dictation. 100% on-device.", 38, 11.5, .regular, NSColor(cgColor: c(0xFFFFFF, 0.6))!)
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img); rep.size = NSSize(width: 660, height: 400)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
SWIFT
BG_DIR="$WORK/bg"; mkdir -p "$BG_DIR"
HAVE_BG=0
if xcrun swift "$BG_SWIFT" "$BG_DIR/bg.png" 1 && xcrun swift "$BG_SWIFT" "$BG_DIR/bg@2x.png" 2 \
   && tiffutil -cathidpicheck "$BG_DIR/bg.png" "$BG_DIR/bg@2x.png" -out "$BG_DIR/background.tiff" >/dev/null 2>&1; then
  HAVE_BG=1; echo "    background.tiff (1x + 2x)"
else
  echo "    WARNING: background generation failed; the DMG will have a plain window" >&2
fi

# ---------------------------------------------------------------------------------------------
echo "==> 5/6 $DMG"
if command -v create-dmg >/dev/null 2>&1; then
  echo "    (create-dmg is installed but not used; plain hdiutil keeps the build dependency-free)"
fi
STAGE="$WORK/stage"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/WisprLocal.app"
ln -s /Applications "$STAGE/Applications"
if [ "$HAVE_BG" = 1 ]; then
  mkdir -p "$STAGE/.background"; cp "$BG_DIR/background.tiff" "$STAGE/.background/background.tiff"
fi
VOLNAME="WisprLocal $APP_VERSION$SUFFIX"
RW="$WORK/rw.dmg"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 80 ))
# Detach any stale mount of the same volume name from an interrupted run.
[ -d "/Volumes/$VOLNAME" ] && hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW"
MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[ -d "$MNT" ] || die "could not mount $RW"
DISK_NAME="$(basename "$MNT")"
LAYOUT_OK=0
# Finder layout. Needs Automation permission for Finder the first time (macOS asks). If it is
# denied or Finder is unavailable, the DMG still works: it just opens with default icon spots.
if osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
  tell disk "$DISK_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    if $HAVE_BG is 1 then set background picture of opts to file ".background:background.tiff"
    set position of item "WisprLocal.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  LAYOUT_OK=1; echo "    Finder layout applied"
else
  echo "    WARNING: Finder layout failed (Automation permission for Finder?). DMG has default layout." >&2
fi
[ "$HAVE_BG" = 1 ] && SetFile -a V "$MNT/.background" 2>/dev/null || true
sync
for i in 1 2 3 4 5; do hdiutil detach "$MNT" -quiet && break; sleep 2; done
[ -d "$MNT" ] && hdiutil detach "$MNT" -force -quiet
# ULFO (lzfse): supported on every macOS this app runs on; faster to open than zlib.
hdiutil convert -quiet "$RW" -format ULFO -o "$DMG"
rm -f "$RW"
hdiutil verify -quiet "$DMG" && echo "    hdiutil verify: OK"

# ---------------------------------------------------------------------------------------------
echo "==> 6/6 checksums"
(cd "$REL" && for f in "${ARTEFACTS[@]}"; do shasum -a 256 "$(basename "$f")"; done) > "$REL/SHA256SUMS$SUFFIX.txt"
cat "$REL/SHA256SUMS$SUFFIX.txt"
echo
ls -lh "${ARTEFACTS[@]}"
SIZE_BYTES=$(stat -f %z "$DMG")
[ "$SIZE_BYTES" -lt 2147483648 ] || echo "WARNING: DMG is over GitHub's 2 GiB release-asset limit" >&2
rm -rf "$WORK"
echo
echo "Done. Nothing was uploaded. Version $APP_VERSION, DR: $DR"
if [ "$ADHOC_DRYRUN" = 1 ]; then
  echo "WARNING: NOT A RELEASE — ad-hoc dry-run artefacts only ($SUFFIX)." >&2
fi
[ "$LAYOUT_OK" = 1 ] || echo "Note: Finder layout was not applied; rerun from a GUI session to get it."
exit 0
