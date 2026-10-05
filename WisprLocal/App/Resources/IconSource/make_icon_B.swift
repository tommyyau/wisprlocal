// WisprLocal app icon (concept B "Local orb") + menu-bar template glyphs.
// CoreGraphics + CoreImage. Usage: swift make_icon_B.swift <outdir>
// Outputs: AppIcon.iconset/, AppIcon.icns (via iconutil), icon-B-1024.png, MenuBarIcon(.png/@2x), MenuBarIconAlert(.png/@2x), preview-B.png
import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ciCtx = CIContext(options: [.workingColorSpace: cs, .outputColorSpace: cs])

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: a)
}
func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func grad(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    let l = locs ?? cols.indices.map { CGFloat($0) / CGFloat(max(cols.count - 1, 1)) }
    return CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: l)!
}
let ext: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
func linear(_ x: CGContext, _ cols: [CGColor], _ p0: CGPoint, _ p1: CGPoint, _ locs: [CGFloat]? = nil) {
    x.drawLinearGradient(grad(cols, locs), start: p0, end: p1, options: ext)
}
func radial(_ x: CGContext, _ cols: [CGColor], _ c0: CGPoint, _ r: CGFloat, _ locs: [CGFloat]? = nil, c1: CGPoint? = nil) {
    x.drawRadialGradient(grad(cols, locs), startCenter: c0, startRadius: 0, endCenter: c1 ?? c0, endRadius: r, options: [.drawsBeforeStartLocation])
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// ---------- geometry helpers (1024 design units, y-down) ----------
func squircle(_ x: CGFloat, _ w: CGFloat, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath(); let a = w/2, cx = x + a
    for i in 0..<720 {
        let t = CGFloat(i)/720 * 2 * .pi, co = cos(t), si = sin(t)
        let q = P(cx + a * (co < 0 ? -1 : 1) * pow(abs(co), 2/n), cx + a * (si < 0 ? -1 : 1) * pow(abs(si), 2/n))
        i == 0 ? p.move(to: q) : p.addLine(to: q)
    }
    p.closeSubpath(); return p
}
// Variable-width stroke as a filled polygon (tapers where width -> 0).
func band(_ pts: [CGPoint], _ ws: [CGFloat]) -> CGPath {
    var L: [CGPoint] = [], R: [CGPoint] = []
    for i in pts.indices {
        let a = pts[max(i-1, 0)], b = pts[min(i+1, pts.count-1)]
        var dx = b.x - a.x, dy = b.y - a.y; let m = max(hypot(dx, dy), 1e-6); dx /= m; dy /= m
        let nx = -dy, ny = dx, h = ws[i]/2
        L.append(P(pts[i].x + nx*h, pts[i].y + ny*h)); R.append(P(pts[i].x - nx*h, pts[i].y - ny*h))
    }
    let p = CGMutablePath(); p.addLines(between: L + R.reversed()); p.closeSubpath(); return p
}
func capsule(_ r: CGRect) -> CGPath { let k = min(r.width, r.height)/2; return CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil) }

// ---------- canvas: layers drawn in flipped 1024 space, composited onto an unflipped base ----------
final class Canvas {
    let S: Int; let k: CGFloat; let base: CGContext; let small: Bool; let tile: CGPath; let tileX: CGFloat, tileW: CGFloat
    init(_ S: Int, small: Bool) {
        self.S = S; k = CGFloat(S)/1024; base = bitmap(S, S); self.small = small
        tileX = small ? 64 : 100; tileW = small ? 896 : 824; tile = squircle(tileX, tileW)
    }
    func layer(clip: Bool = true, _ f: (CGContext) -> Void) -> CGImage {
        let x = bitmap(S, S); x.translateBy(x: 0, y: CGFloat(S)); x.scaleBy(x: k, y: -k)
        if clip { x.addPath(tile); x.clip() }
        f(x); return x.makeImage()!
    }
    func blur(_ img: CGImage, _ r: CGFloat) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: S, height: S)
        let ci = CIImage(cgImage: img).applyingGaussianBlur(sigma: Double(r * k)).cropped(to: rect)
        return ciCtx.createCGImage(ci, from: rect)!
    }
    func put(_ img: CGImage, _ mode: CGBlendMode = .normal, _ a: CGFloat = 1, dy: CGFloat = 0, clipTile: Bool = false) {
        base.saveGState(); base.setBlendMode(mode); base.setAlpha(a)
        if clipTile { // tile is symmetric, so the y-up path is just a scale
            var t = CGAffineTransform(scaleX: k, y: k); if let p = tile.copy(using: &t) { base.addPath(p); base.clip() }
        }
        base.draw(img, in: CGRect(x: 0, y: -dy * k, width: CGFloat(S), height: CGFloat(S))); base.restoreGState()
    }
    // shared macOS 26 tile chrome
    func shadow() {
        if small { return }
        let s = layer(clip: false) { $0.addPath(self.tile); $0.setFillColor(c(0, 1)); $0.fillPath() }
        put(blur(s, 16), .normal, 0.38, dy: 14)
    }
    func chrome(sheen: CGFloat = 0.10, rim: CGFloat = 0.16) {
        put(layer { x in linear(x, [c(0xFFFFFF, sheen), c(0xFFFFFF, 0)], P(0, self.tileX), P(0, 560)) }, .screen)
        if small { return }
        put(layer { x in
            x.addPath(self.tile); x.setLineWidth(5)
            x.replacePathWithStrokedPath(); x.clip()
            linear(x, [c(0xFFFFFF, rim * 1.6), c(0xFFFFFF, rim * 0.2), c(0xFFFFFF, rim * 0.7)], P(0, 100), P(0, 924), [0, 0.55, 1])
        })
    }
    var image: CGImage { base.makeImage()! }
}

// ---------- Local orb: a glass sphere holding a glowing voice ----------
struct BarSpec { var x, w, y, h: CGFloat }         // in 1024 design units
struct OrbLayout { var cx, cy, R: CGFloat; var bars: [BarSpec]; var corner: CGFloat; var px: Int }

func layout(px: Int) -> OrbLayout {
    if px == 16 || px == 32 {
        // hand-tuned on the target pixel grid; every edge lands on a whole pixel
        let u = CGFloat(1024 / px)
        let g: (CGFloat, CGFloat, CGFloat, [(CGFloat, CGFloat, CGFloat, CGFloat)]) = px == 16
            ? (8, 8, 6, [(4, 2, 6, 4), (7, 2, 4, 8), (10, 2, 6, 4)])
            : (16, 16, 12, [(7, 2, 13, 6), (11, 2, 10, 12), (15, 2, 8, 16), (19, 2, 11, 10), (23, 2, 13, 6)])
        return OrbLayout(cx: g.0*u, cy: g.1*u, R: g.2*u,
                         bars: g.3.map { BarSpec(x: $0.0*u, w: $0.1*u, y: $0.2*u, h: $0.3*u) }, corner: px == 16 ? 0.5*u : u, px: px)
    }
    let cx: CGFloat = 512, cy: CGFloat = 488, R: CGFloat = 300
    let hs: [CGFloat] = [0.20, 0.42, 0.70, 0.98, 0.62, 0.38, 0.18]
    let bw: CGFloat = 34, gap: CGFloat = 30, total = CGFloat(hs.count) * bw + CGFloat(hs.count - 1) * gap
    let bars = hs.enumerated().map { (i, h) -> BarSpec in
        let bh = h * R * 1.12; return BarSpec(x: cx - total/2 + CGFloat(i) * (bw + gap), w: bw, y: cy - bh/2, h: bh) }
    return OrbLayout(cx: cx, cy: cy, R: R, bars: bars, corner: bw/2, px: px)
}

func drawOrb(_ v: Canvas, _ L: OrbLayout) {
    let cx = L.cx, cy = L.cy, R = L.R, small = v.small, px1 = 1024 / CGFloat(L.px)   // px1 = one target pixel in design units
    v.shadow()
    v.put(v.layer { x in
        linear(x, [c(0x1B1145), c(0x07051A)], P(0, v.tileX), P(0, v.tileX + v.tileW))
        radial(x, [c(0x5B3BFF, small ? 0.55 : 0.45), c(0x5B3BFF, 0)], P(cx, cy), R * 1.55)
    })
    let orb = CGPath(ellipseIn: CGRect(x: cx - R, y: cy - R, width: 2*R, height: 2*R), transform: nil)
    if !small { // contact shadow + bounce light on the "floor"
        let fl = v.layer { x in x.addEllipse(in: CGRect(x: cx - 230, y: cy + R + 26, width: 460, height: 56)); x.setFillColor(c(0x000000, 0.9)); x.fillPath() }
        v.put(v.blur(fl, 26), .normal, 0.75)
        let bounce = v.layer { x in x.addEllipse(in: CGRect(x: cx - 170, y: cy + R + 20, width: 340, height: 40)); x.setFillColor(c(0x3FF0D0, 1)); x.fillPath() }
        v.put(v.blur(bounce, 30), .screen, 0.35)
    }
    v.put(v.layer { x in   // glass body + caustic pooling at the base
        x.addPath(orb); x.clip()
        radial(x, [c(0x2C1D78, 0.96), c(0x170E48, 0.98), c(0x0B0726, 1)], P(cx, cy + R*0.25), R * 1.05, [0, 0.6, 1], c1: P(cx, cy))
        radial(x, [c(0x34F5D2, L.px == 16 ? 0.12 : (small ? 0.40 : 0.55)), c(0x34F5D2, 0)], P(cx, cy + R * 0.95), R * 0.95)
    })
    let bars = CGMutablePath()
    for b in L.bars { bars.addPath(CGPath(roundedRect: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), cornerWidth: L.corner, cornerHeight: L.corner, transform: nil)) }
    let wave = v.layer { x in x.addPath(orb); x.clip(); x.addPath(bars); x.clip()
        linear(x, [c(0x9CFFE9), c(0xFFFFFF), c(0x6FF2D2)], P(0, cy - R*0.55), P(0, cy + R*0.55), [0, 0.5, 1]) }
    if L.px == 16 {
        // no glow at 16 px: the 1px gaps between bars must stay dark
    } else if small {
        v.put(v.blur(wave, 1.2 * px1), .screen, 0.55)   // a whisper of glow only; keeps the 1px gaps open
    } else {
        v.put(v.blur(wave, 30), .screen, 1.0); v.put(v.blur(wave, 10), .screen, 0.6)
    }
    v.put(wave)
    v.put(v.layer { x in x.addPath(orb); x.clip()   // fresnel edge
        radial(x, [c(0xA99BFF, 0), c(0xA99BFF, 0), c(0xC8BDFF, 0.45)], P(cx, cy), R, [0, 0.78, 1]) }, .screen)
    // rim light: 5 units at large sizes, exactly one pixel at 16/32 so the orb separates from the tile
    let rimW: CGFloat = small ? px1 : 5
    let rimOrb = small ? CGPath(ellipseIn: CGRect(x: cx - R + rimW/2, y: cy - R + rimW/2, width: 2*R - rimW, height: 2*R - rimW), transform: nil) : orb
    v.put(v.layer { x in x.addPath(rimOrb); x.setLineWidth(rimW); x.replacePathWithStrokedPath(); x.clip()
        linear(x, [c(0xFFFFFF, small ? 0.75 : 0.85), c(0xFFFFFF, small ? 0.20 : 0.05), c(0x5FF5DA, small ? 0.7 : 0.8)], P(0, cy - R), P(0, cy + R), [0, 0.5, 1]) }, .screen)
    v.put(v.layer { x in   // crescent specular (window reflection)
        x.addPath(orb); x.clip()
        x.translateBy(x: cx - R*0.32, y: cy - R*0.56); x.rotate(by: -0.42)
        x.addEllipse(in: CGRect(x: -R*0.50, y: -R*0.20, width: R*1.00, height: R*0.40)); x.clip()
        linear(x, [c(0xFFFFFF, 0.75), c(0xFFFFFF, 0.0)], P(0, -R*0.20), P(0, R*0.12))
        x.setBlendMode(.clear); x.addEllipse(in: CGRect(x: -R*0.56, y: -R*0.06, width: R*1.12, height: R*0.46)); x.fillPath()
    }, .screen, small ? 0.8 : 1)
    if !small {
        v.put(v.blur(v.layer { x in x.addEllipse(in: CGRect(x: cx + R*0.42, y: cy + R*0.42, width: 40, height: 22)); x.setFillColor(c(0xFFFFFF)); x.fillPath() }, 6), .screen, 0.7)
    }
    v.chrome(sheen: 0.06, rim: 0.12)
}

func renderIcon(px: Int) -> CGImage {
    let v = Canvas(px, small: px <= 32)      // 16/32 are drawn natively on their own pixel grid (no resampling)
    drawOrb(v, layout(px: px)); return v.image
}

// ---------- menu-bar template glyphs: ring + five voice bars, one variant per app state ----------
// Separate, pixel-snapped geometry per scale, in pixels (y-down). Variants (MenuBarIconState):
//   idle       ring 1.5 pt + bars
//   warm       mic ready: ring thickened to 2.5 pt (centre bar shortened to keep its gap)
//   recording  solid orb with the bars knocked out
//   holdingOff idle glyph struck through by a slash (with a clear moat), for Wispr Flow
//   alert      idle glyph + badge dot (error)
// crescent highlight was tested and muddies the ring at 18 pt, so it is off by default
enum GlyphVariant: String, CaseIterable { case idle, warm, recording, holdingOff, alert }

func menuGlyph(scale: Int, alert: Bool, crescent: Bool = false) -> CGImage {
    menuGlyph(scale: scale, variant: alert ? .alert : .idle, crescent: crescent)
}

func menuGlyph(scale: Int, variant: GlyphVariant, crescent: Bool = false) -> CGImage {
    let px = 18 * scale, x = bitmap(px, px)
    x.translateBy(x: 0, y: CGFloat(px)); x.scaleBy(x: 1, y: -1)
    x.setFillColor(c(0)); x.setStrokeColor(c(0))
    // ring (1.5 pt): @1x centre at 8.5 so the 1px bars sit on whole pixels; @2x everything is integral
    let ccx: CGFloat = scale == 1 ? 8.5 : 18, ccy: CGFloat = scale == 1 ? 9 : 18
    let rOut: CGFloat = scale == 1 ? 8 : 16
    let sw: CGFloat = variant == .warm ? (scale == 1 ? 2.5 : 5) : (scale == 1 ? 1.5 : 3)
    let outer = CGRect(x: ccx - rOut, y: ccy - rOut, width: 2*rOut, height: 2*rOut)
    // five bars, centre tallest: (x, y, w, h)
    var barSpecs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = scale == 1
        ? [(4, 7, 1, 4), (6, 6, 1, 6), (8, 4, 1, 10), (10, 6, 1, 6), (12, 7, 1, 4)]
        : [(9, 14, 2, 8), (13, 11, 2, 14), (17, 8, 2, 20), (21, 11, 2, 14), (25, 14, 2, 8)]
    if variant == .warm { barSpecs[2] = scale == 1 ? (8, 5, 1, 8) : (17, 10, 2, 16) }
    let bars = CGMutablePath()
    for b in barSpecs { bars.addPath(CGPath(roundedRect: CGRect(x: b.0, y: b.1, width: b.2, height: b.3), cornerWidth: b.2/2, cornerHeight: b.2/2, transform: nil)) }

    if variant == .recording {
        // solid orb, bars knocked out
        x.fillEllipse(in: outer)
        x.setBlendMode(.clear)
        x.addPath(bars); x.fillPath()
        x.setBlendMode(.normal)
        return x.makeImage()!
    }
    let ring = CGMutablePath()
    ring.addEllipse(in: outer)
    ring.addEllipse(in: outer.insetBy(dx: sw, dy: sw))
    x.addPath(ring); x.fillPath(using: .evenOdd)
    x.addPath(bars); x.fillPath()
    if crescent && scale == 2 {
        // crescent highlight: a short inner arc hugging the ring's top-left, clear of the bars
        x.setLineWidth(2); x.setLineCap(.round)
        x.addArc(center: P(ccx, ccy), radius: 10.5, startAngle: .pi * 1.18, endAngle: .pi * 1.36, clockwise: false); x.strokePath()
    }
    if variant == .holdingOff {
        // slash top-left → bottom-right, knocked out of the glyph with a clear moat on both sides
        let a = scale == 1 ? P(2, 2.5) : P(4, 4), b = scale == 1 ? P(15, 15.5) : P(32, 32)
        let w: CGFloat = scale == 1 ? 1.5 : 3, moat: CGFloat = scale == 1 ? 1.25 : 2.5
        x.setLineCap(.round)
        x.setBlendMode(.clear); x.setLineWidth(w + 2*moat)
        x.move(to: a); x.addLine(to: b); x.strokePath()
        x.setBlendMode(.normal); x.setLineWidth(w)
        x.move(to: a); x.addLine(to: b); x.strokePath()
    }
    if variant == .alert {
        // badge dot top-right, knocked out of the ring with a clear moat
        let dc = scale == 1 ? P(14.5, 3.5) : P(29, 7), dr: CGFloat = scale == 1 ? 2.5 : 5, moat: CGFloat = scale == 1 ? 1 : 2
        x.setBlendMode(.clear); x.fillEllipse(in: CGRect(x: dc.x - dr - moat, y: dc.y - dr - moat, width: 2*(dr + moat), height: 2*(dr + moat)))
        x.setBlendMode(.normal); x.fillEllipse(in: CGRect(x: dc.x - dr, y: dc.y - dr, width: 2*dr, height: 2*dr))
    }
    return x.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

// ---------- outputs ----------
let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
var I: [Int: CGImage] = [:]
for p in [16, 32, 64, 128, 256, 512, 1024] { I[p] = renderIcon(px: p) }
// @2x of 16 is 32 px: use the 32 px pixel-tuned rendition there as well
for (n, p) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
               ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    writePNG(I[p]!, "\(iconset)/icon_\(n).png")
}
writePNG(I[1024]!, "\(out)/icon-B-1024.png")
let g1 = menuGlyph(scale: 1, alert: false), g2 = menuGlyph(scale: 2, alert: false)
let a1 = menuGlyph(scale: 1, alert: true), a2 = menuGlyph(scale: 2, alert: true)
writePNG(g1, "\(out)/MenuBarIcon.png"); writePNG(g2, "\(out)/MenuBarIcon@2x.png")
writePNG(a1, "\(out)/MenuBarIconAlert.png"); writePNG(a2, "\(out)/MenuBarIconAlert@2x.png")
// state variants (names match MenuBarIconState.resourceName in WisprLocalCore)
let variantFiles: [(GlyphVariant, String)] = [(.warm, "MenuBarIconWarm"), (.recording, "MenuBarIconRecording"),
                                              (.holdingOff, "MenuBarIconHoldingOff")]
for (v, name) in variantFiles {
    writePNG(menuGlyph(scale: 1, variant: v), "\(out)/\(name).png"); writePNG(menuGlyph(scale: 2, variant: v), "\(out)/\(name)@2x.png")
}

// ---------- preview sheet ----------
func glyphOn(_ x: CGContext, _ g: CGImage, _ r: CGRect, white: Bool) {
    x.saveGState(); x.clip(to: r, mask: g); x.setFillColor(CGColor(gray: white ? 1 : 0, alpha: 0.88)); x.fill(r); x.restoreGState()
}
func label(_ x: CGContext, _ s: String, _ at: CGPoint, _ gray: CGFloat) {
    let font = CTFontCreateUIFontForLanguage(.system, 18, nil)!
    let a = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                       kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: gray, alpha: 1)])
    x.textPosition = at; CTLineDraw(CTLineCreateWithAttributedString(a), x)
}
let W = 1900, PH = 620, H = PH * 2
let sh = bitmap(W, H)
for (pi, dark) in [false, true].enumerated() {
    let y0 = CGFloat(H - (pi + 1) * PH), fg: CGFloat = dark ? 0.65 : 0.4
    sh.setFillColor(CGColor(gray: dark ? 0.12 : 0.95, alpha: 1)); sh.fill(CGRect(x: 0, y: y0, width: CGFloat(W), height: CGFloat(PH)))
    sh.interpolationQuality = .high
    sh.draw(I[1024]!, in: CGRect(x: 30, y: y0 + 70, width: 512, height: 512)); label(sh, "1024 (shown 512)", P(40, y0 + 36), fg)
    sh.interpolationQuality = .none
    sh.draw(I[128]!, in: CGRect(x: 580, y: y0 + 260, width: 128, height: 128)); label(sh, "128", P(625, y0 + 226), fg)
    sh.draw(I[32]!, in: CGRect(x: 740, y: y0 + 308, width: 32, height: 32)); label(sh, "32", P(744, y0 + 226), fg)
    sh.draw(I[16]!, in: CGRect(x: 800, y: y0 + 316, width: 16, height: 16)); label(sh, "16", P(798, y0 + 226), fg)
    sh.draw(I[32]!, in: CGRect(x: 860, y: y0 + 200, width: 256, height: 256)); label(sh, "32 ×8", P(960, y0 + 166), fg)
    sh.draw(I[16]!, in: CGRect(x: 1140, y: y0 + 200, width: 256, height: 256)); label(sh, "16 ×16", P(1235, y0 + 166), fg)
    // menu bar at actual size + magnified glyphs
    let mb = CGRect(x: 1430, y: y0 + 470, width: 440, height: 48)
    sh.setFillColor(CGColor(gray: dark ? 0.2 : 0.88, alpha: 1)); sh.fill(mb)
    glyphOn(sh, g1, CGRect(x: mb.minX + 20, y: mb.minY + 15, width: 18, height: 18), white: dark)
    glyphOn(sh, a1, CGRect(x: mb.minX + 60, y: mb.minY + 15, width: 18, height: 18), white: dark)
    glyphOn(sh, g2, CGRect(x: mb.minX + 120, y: mb.minY + 6, width: 36, height: 36), white: dark)
    glyphOn(sh, a2, CGRect(x: mb.minX + 176, y: mb.minY + 6, width: 36, height: 36), white: dark)
    label(sh, "menu bar: @1x, alert @1x, @2x, alert @2x (actual px)", P(1430, y0 + 440), fg)
    sh.interpolationQuality = .none
    glyphOn(sh, g1, CGRect(x: 1430, y: y0 + 200, width: 198, height: 198), white: dark); label(sh, "@1x ×11", P(1490, y0 + 166), fg)
    glyphOn(sh, a2, CGRect(x: 1660, y: y0 + 200, width: 198, height: 198), white: dark); label(sh, "alert @2x ×5.5", P(1700, y0 + 166), fg)
}
writePNG(sh.makeImage()!, "\(out)/preview-B.png")
// ---------- menu-bar state contact sheet: every variant at 18 pt (@1x, @2x) on light and dark bars ----------
let states: [(GlyphVariant, String)] = [(.idle, "idle"), (.warm, "mic ready"), (.recording, "recording"),
                                        (.holdingOff, "holding off"), (.alert, "error")]
let colW = 190, CW = 40 + colW * states.count, CH = 2 * 300
let cs2 = bitmap(CW, CH)
for (pi, dark) in [false, true].enumerated() {
    let y0 = CGFloat(CH - (pi + 1) * 300), fg: CGFloat = dark ? 0.7 : 0.35
    cs2.setFillColor(CGColor(gray: dark ? 0.12 : 0.96, alpha: 1)); cs2.fill(CGRect(x: 0, y: y0, width: CGFloat(CW), height: 300))
    label(cs2, dark ? "dark menu bar" : "light menu bar", P(20, y0 + 268), fg)
    for (i, (v, name)) in states.enumerated() {
        let x0 = CGFloat(20 + i * colW)
        let bar = CGRect(x: x0, y: y0 + 196, width: CGFloat(colW - 20), height: 44)
        cs2.setFillColor(CGColor(gray: dark ? 0.22 : 0.86, alpha: 1)); cs2.fill(bar)
        let g1 = menuGlyph(scale: 1, variant: v), g2 = menuGlyph(scale: 2, variant: v)
        cs2.interpolationQuality = .none
        glyphOn(cs2, g1, CGRect(x: bar.minX + 24, y: bar.minY + 13, width: 18, height: 18), white: dark)
        glyphOn(cs2, g2, CGRect(x: bar.minX + 84, y: bar.minY + 4, width: 36, height: 36), white: dark)
        glyphOn(cs2, g2, CGRect(x: x0 + 25, y: y0 + 46, width: 126, height: 126), white: dark)
        label(cs2, name, P(x0 + 4, y0 + 14), fg)
    }
    label(cs2, "bar: @1x and @2x pixels at actual size; below: @2x ×3.5", P(CGFloat(CW) - 560, y0 + 268), fg)
}
writePNG(cs2.makeImage()!, "\(out)/menu-states.png")
print("ok")
