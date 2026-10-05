import AppKit
import SwiftUI

/// WisprLocal design tokens — the one place colours, type, spacing and surfaces are defined.
/// Brand: the app-icon orb — deep indigo/violet glass with mint (#7CF5D4) voice bars.
enum Theme {
    // MARK: brand colours
    static let indigoDeep = Color(hex: 0x120D2E)
    static let indigo = Color(hex: 0x1B1440)       // HUD glass tint
    static let violet = Color(hex: 0x3A2D7A)
    static let violetGlow = Color(hex: 0x6B5BD6)
    static let mint = Color(hex: 0x7CF5D4)
    static let mintDeep = Color(hex: 0x5BE3C0)
    /// Mint is too light for text on white; this darker teal carries the accent in light mode.
    static let accent = Color(light: Color(hex: 0x0E9F80), dark: Color(hex: 0x7CF5D4))
    static let accentSoft = Color(light: Color(hex: 0x0E9F80).opacity(0.12), dark: Color(hex: 0x7CF5D4).opacity(0.14))
    static let positive = Color(light: Color(hex: 0x1F9D55), dark: Color(hex: 0x4ADE80))
    static let warning = Color(light: Color(hex: 0xC2410C), dark: Color(hex: 0xFDBA74))
    static let danger = Color(light: Color(hex: 0xC62828), dark: Color(hex: 0xFF8A80))
    /// Status tints on always-dark surfaces (hero gradient, HUD), whatever the appearance.
    static let onDarkWarning = Color(hex: 0xFDBA74)
    static let onDarkDanger = Color(red: 1, green: 0.42, blue: 0.40)
    /// Text on the mint brand button.
    static let onMint = Color(hex: 0x0D2B25)

    // MARK: surfaces
    static let windowBackground = Color(light: Color(hex: 0xF6F5FA), dark: Color(hex: 0x16141F))
    static let card = Color(light: .white, dark: Color(hex: 0x211E2E))
    static let cardBorder = Color(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.08))
    static let inset = Color(light: Color(hex: 0xF1F0F6), dark: Color(hex: 0x2A2639))
    /// Preview-only stand-in for the Liquid Glass sidebar.
    static let sidebarSimulated = Color(light: Color(hex: 0xECEBF3), dark: Color(hex: 0x1D1A28))
    static let separator = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.07))
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    /// Hero areas: the orb's indigo → violet glass.
    static let heroGradient = LinearGradient(
        stops: [.init(color: Color(hex: 0x241A5C), location: 0),
                .init(color: Color(hex: 0x1B1440), location: 0.55),
                .init(color: Color(hex: 0x0F2A3A), location: 1)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let mintGradient = LinearGradient(colors: [mint, mintDeep], startPoint: .top, endPoint: .bottom)
    /// The drawn orb's glass, centre → rim.
    static let orbStops = [Color(hex: 0x2B2470), Color(hex: 0x17123F), Color(hex: 0x0F3346)]
    /// `KeyCap` face gradient, top → bottom, per appearance.
    static let keyCapLight = [Color.white, Color(hex: 0xECEBF2)]
    static let keyCapDark = [Color(hex: 0x3B3750), Color(hex: 0x2A2739)]

    // MARK: preview harness only (UIPreview / HUDPreview backdrops, never in the app)
    static let previewBackdropHUD = [Color(hex: 0x2B3245), Color(hex: 0x3B2D44)]
    static let previewBackdropDark = [Color(red: 0.10, green: 0.12, blue: 0.18), Color(red: 0.22, green: 0.14, blue: 0.24)]
    static let previewBackdropLight = [Color(red: 0.86, green: 0.90, blue: 0.97), Color(red: 0.97, green: 0.90, blue: 0.84)]

    // MARK: geometry
    /// Spacing scale. Paddings and gaps use these, never literals (`DesignTokenLintTests`).
    enum Space {
        static let hair: CGFloat = 2, xxs: CGFloat = 4, tight: CGFloat = 6, xs: CGFloat = 8, snug: CGFloat = 10, s: CGFloat = 12,
                   ms: CGFloat = 14, m: CGFloat = 16, ml: CGFloat = 20, l: CGFloat = 24, xl: CGFloat = 32, xxl: CGFloat = 48
    }
    /// Corner radii (always `.continuous`). Literals are not allowed outside this file.
    enum Radius {
        static let tiny: CGFloat = 4, well: CGFloat = 6, small: CGFloat = 8, tile: CGFloat = 10, card: CGFloat = 14, hero: CGFloat = 20
    }
    static let contentMaxWidth: CGFloat = 760

    // MARK: type scale (SF Pro; SF Pro Rounded for numbers & display)
    enum Typo {
        static let menuDotDiameter: CGFloat = 2.5
        static let display = Font.system(size: 28, weight: .bold, design: .rounded)
        static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let section = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyEmphasis = Font.system(size: 13, weight: .medium)
        static let caption = Font.system(size: 11.5)
        static let eyebrow = Font.system(size: 10.5, weight: .semibold).smallCaps()
        /// Onboarding welcome headline on the hero gradient.
        static let heroDisplay = Font.system(size: 32, weight: .bold, design: .rounded)
        /// Editorial hero headline (Snippets empty state).
        static let heroHeadline = Font.system(size: 30, weight: .semibold, design: .serif)
        /// Headline numerals: total words, speaking speed, current streak.
        static let heroNumber = Font.system(size: 40, weight: .semibold, design: .rounded)
        /// Home stat numerals.
        static let bigNumber = Font.system(size: 34, weight: .semibold, design: .rounded)
        /// Secondary numerals inside tiles (counts, longest streak).
        static let statValue = Font.system(size: 24, weight: .semibold, design: .rounded)
        /// Unit beside a numeral ("days", "wpm").
        static let numberUnit = Font.system(size: 14, weight: .medium, design: .rounded)
        /// Inline numeric values in rows (percentages, counts).
        static let figure = Font.system(size: 13, weight: .semibold, design: .rounded)
        /// Small numeric captions and deltas.
        static let figureCaption = Font.system(size: 11.5, design: .rounded)
        /// The sidebar wordmark.
        static let wordmark = Font.system(size: 15, weight: .semibold, design: .rounded)
        /// Hero subtitles and practice text fields.
        static let lead = Font.system(size: 14)
        static let statLabel = Font.system(size: 11.5, weight: .medium)
        static let keyCap = Font.system(size: 15, weight: .medium, design: .rounded)
        /// The legend ("fn") and glyph on a `KeyCap`, proportional to the key's size.
        static func keyCapLegend(_ keySize: CGFloat) -> Font { .system(size: keySize * 0.22, weight: .medium, design: .rounded) }
        static func keyCapGlyph(_ keySize: CGFloat, labelled: Bool) -> Font { .system(size: keySize * (labelled ? 0.34 : 0.42)) }
        /// Settings / section eyebrow above a card (shown uppercased with +0.6 kerning).
        static let groupHeader = Font.system(size: 11, weight: .semibold)
        /// The segmented tab bar and other small pill labels.
        static let chip = Font.system(size: 12, weight: .medium)
        /// Tiny badges ("BETA", "NEW").
        static let badge = Font.system(size: 9.5, weight: .bold)
        /// SF Symbols inline with body text or inside a field.
        static let symbol = Font.system(size: 11, weight: .medium)
        static let symbolLarge = Font.system(size: 13, weight: .semibold)
        /// Standalone status and feature icons beside a block of text.
        static let icon = Font.system(size: 18)
        /// Empty-state glyphs.
        static let iconLarge = Font.system(size: 26)
        /// Small labels: tags, footnotes, month labels.
        static let footnote = Font.system(size: 10.5, weight: .medium)
        /// Chart axis labels (gauge scale, weekday rows).
        static let axis = Font.system(size: 9.5, weight: .medium, design: .rounded)
        /// Tiny bold glyphs: inline arrows, remove (×) marks, play/stop, check marks.
        static let micro = Font.system(size: 9, weight: .bold)
        /// Up-down chevrons in pick-one fields.
        static let chevron = Font.system(size: 9, weight: .semibold)
        /// Paths, keys and other monospaced fragments.
        static let mono = Font.system(size: 10.5, design: .monospaced)
        /// HUD notice text and buttons. The sizes are shared with `HUDNoticeMetrics`, which
        /// measures the same text with NSFont, so the two can never drift apart.
        static let hudTextSize: CGFloat = 13, hudButtonSize: CGFloat = 12
        static let hudText = Font.system(size: hudTextSize, weight: .medium)
        static let hudButton = Font.system(size: hudButtonSize, weight: .semibold)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// Appearance-adaptive colour (resolved by AppKit per light/dark).
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

// MARK: - Surfaces

/// The standard content card: solid, softly bordered, a whisper of shadow.
struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.Space.m
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.cardBorder))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

extension View {
    func card(padding: CGFloat = Theme.Space.m) -> some View { modifier(CardModifier(padding: padding)) }
}
