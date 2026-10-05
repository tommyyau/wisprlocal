import AppKit
import SwiftUI
import WisprLocalCore

// MARK: - Key cap

/// A physical-looking key: the 🌐 / fn key WisprLocal listens to.
struct KeyCap: View {
    var symbol: String = "globe"
    var label: String? = "fn"
    var size: CGFloat = 44
    var pressed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(LinearGradient(colors: scheme == .dark ? Theme.keyCapDark : Theme.keyCapLight,
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12), lineWidth: 0.75)
            if let label {
                Text(label).font(Theme.Typo.keyCapLegend(size))
                    .foregroundStyle(.secondary)
                    .padding(.top, size * 0.11).padding(.leading, size * 0.14)
            }
            Image(systemName: symbol)
                .font(Theme.Typo.keyCapGlyph(size, labelled: label != nil))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: label == nil ? .center : .bottomTrailing)
                .padding(label == nil ? 0 : size * 0.13)
        }
        .frame(width: size, height: size)
        .background(shape.fill(scheme == .dark ? Color.black.opacity(0.55) : Color.black.opacity(0.16)).offset(y: pressed ? 0.5 : size * 0.05))
        .offset(y: pressed ? size * 0.04 : 0)
        .accessibilityLabel("Globe key (fn)")
    }
}

/// Inline key-cap for sentences: "Hold [🌐 fn] and speak".
struct InlineKey: View {
    var text: String = "fn"
    var symbol: String? = "globe"
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(Theme.Typo.symbol) }
            Text(text).font(Theme.Typo.symbol)
        }
        .padding(.horizontal, Theme.Space.tight).frame(height: 19)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous).fill(Theme.inset))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.well, style: .continuous).strokeBorder(Theme.cardBorder))
    }
}

// MARK: - Wave motif (the HUD's mint bar-wave, as decoration)

/// Mint capsule bars rolling in a soft travelling wave — the HUD's look. Animates at 30 fps
/// unless Reduce Motion is on (then it holds a still, pleasant shape). `time` pins a frame
/// for offscreen previews.
struct WaveMotif: View {
    var bars = 21
    var barWidth: CGFloat = 5
    var gap: CGFloat = 6
    var maxHeight: CGFloat = 54
    var intensity: Double = 1
    var time: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let time {
            canvas(t: time)
        } else if reduceMotion {
            canvas(t: 1.3)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in canvas(t: ctx.date.timeIntervalSinceReferenceDate) }
        }
    }

    static func level(i: Int, n: Int, t: Double) -> Double {
        let x = Double(i) / Double(max(1, n - 1))
        let bell = exp(-pow((x - 0.5) * 2.6, 2))                       // taller in the middle, like the orb
        let travel = 0.5 + 0.5 * sin(x * 9.0 - t * 2.2)                 // slow travelling wave
        let breathe = 0.5 + 0.5 * sin(x * 4.0 + t * 1.3 + 1.1)
        return min(1, 0.18 + bell * (0.45 * travel + 0.37 * breathe))
    }

    private func canvas(t: Double) -> some View {
        let width = CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap
        return Canvas { ctx, size in
            let mid = size.height / 2
            for i in 0..<bars {
                let v = Self.level(i: i, n: bars, t: t) * intensity
                let h = max(barWidth, CGFloat(v) * maxHeight)
                let x = CGFloat(i) * (barWidth + gap)
                let r = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
                let path = Path(roundedRect: r, cornerRadius: barWidth / 2, style: .continuous)
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Theme.mint, Theme.mintDeep]), startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY))
                ctx.opacity = 0.55 + 0.45 * v
                ctx.drawLayer { l in
                    l.addFilter(.shadow(color: Theme.mint.opacity(0.55 * v), radius: 5))
                    l.fill(path, with: shading)
                }
            }
        }
        .frame(width: width, height: maxHeight + 12)
        .accessibilityHidden(true)
    }
}

// MARK: - Orb (the app icon's glass sphere, drawn)

struct Orb: View {
    var size: CGFloat = 120
    var time: Double?

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: Theme.orbStops,
                                         center: UnitPoint(x: 0.45, y: 0.35), startRadius: 0, endRadius: size * 0.62))
            Circle().fill(RadialGradient(colors: [Theme.mint.opacity(0.35), .clear], center: UnitPoint(x: 0.5, y: 0.95),
                                         startRadius: 0, endRadius: size * 0.45))
            WaveMotif(bars: 7, barWidth: size * 0.065, gap: size * 0.055, maxHeight: size * 0.42, time: time)
            // Sheen + rim, so it reads as glass.
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.5, height: size * 0.17)
                .rotationEffect(.degrees(-18))
                .offset(x: -size * 0.13, y: -size * 0.3)
                .blur(radius: 0.6)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), Theme.mint.opacity(0.6)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: max(1, size * 0.012))
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.mint.opacity(0.18), radius: size * 0.18, y: size * 0.08)
        .accessibilityHidden(true)
    }
}

// MARK: - Page scaffolding

/// Every main-window page: a large rounded title, a one-line "what this is", content.
struct Page<Content: View>: View {
    let title: String
    var subtitle: String?
    var trailing: AnyView?
    var info: InfoTopic? = nil
    @ViewBuilder var content: Content

    /// When present, the title and this region stay above the single content scroll view.
    var pinnedHeader: AnyView? = nil
    var measure: ((CGFloat, CGFloat) -> Void)? = nil
    var lazy = false

    private var heading: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                HStack(spacing: Theme.Space.tight) {
                    Text(title).font(Theme.Typo.display)
                    if let info { InfoButton(topic: info) }
                }
                if let subtitle { Text(subtitle).font(Theme.Typo.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Theme.Space.s)
            if let trailing { trailing.fixedSize() }
        }
    }

    var body: some View {
        GeometryReader { page in
            VStack(spacing: 0) {
                if let pinnedHeader {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        heading
                        pinnedHeader.environment(\.settingsViewportHeight, page.size.height)
                    }
                        .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.l).padding(.bottom, Theme.Space.s)
                        .frame(maxWidth: Theme.contentMaxWidth).frame(maxWidth: .infinity)
                }
                ScrollView {
                    pageContent
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, pinnedHeader == nil ? Theme.Space.l : Theme.Space.s)
                    .padding(.bottom, Theme.Space.xl)
                    .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: PageContentHeight.self, value: g.size.height)
                    })
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: PageViewportHeight.self, value: g.size.height)
                })
            }
            .onPreferenceChange(PageContentHeight.self) { h in
                guard let measure else { return }
                contentHeight = h
                measure(h, viewportHeight)
             }
            .onPreferenceChange(PageViewportHeight.self) { h in
                guard let measure else { return }
                viewportHeight = h
                measure(contentHeight, h)
             }
            .scrollContentBackground(.hidden)
            .background(Theme.windowBackground)
        }
    }
    @ViewBuilder private var pageContent: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0) {
                if pinnedHeader == nil { heading.padding(.bottom, Theme.Space.l) }
                content
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if pinnedHeader == nil { heading }
                content
            }
        }
    }
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
}

private struct PageContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct PageViewportHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A titled group of settings rows inside one card.
struct SettingsGroup<Content: View>: View {
    let title: String
    var symbol: String?
    var showHeader = true
    var footer: String?
    var info: InfoTopic? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if showHeader { SettingsGroupHeader(title: title, symbol: symbol, info: info) }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.cardBorder))
            if let footer {
                Text(footer).font(Theme.Typo.caption).foregroundStyle(.secondary).padding(.horizontal, Theme.Space.xxs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SettingsGroup {
    /// A Settings page section: title and symbol come from `SettingsSection`.
    init(section: SettingsSection, footer: String? = nil, info: InfoTopic? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: section.title, symbol: section.symbol, showHeader: false, footer: footer, info: info, content: content)
    }
}

/// The small-caps eyebrow above a settings card (symbol, title, optional badge and ⓘ).
struct SettingsGroupHeader: View {
    let title: String
    var symbol: String?
    var badge: String?
    var info: InfoTopic?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(Theme.Typo.symbol.weight(.semibold)).foregroundStyle(Theme.accent) }
            Text(title.uppercased()).font(Theme.Typo.groupHeader).kerning(0.6).foregroundStyle(.secondary)
            if let badge {
                Text(badge.uppercased()).font(Theme.Typo.badge).kerning(0.6).foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.Space.tight).padding(.vertical, Theme.Space.hair)
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
                    .accessibilityLabel(badge)
            }
            if let info { InfoButton(topic: info) }
        }
        .padding(.leading, Theme.Space.xxs)
    }
}

/// One settings row: title, a one-line "why", and a control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var why: String?
    var divider = true
    var info: InfoTopic? = nil
    var captionWarning = false
    var keepsControlInline = false
    @ViewBuilder var control: Control

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(Theme.Typo.bodyEmphasis)
                if let info { InfoButton(topic: info) }
            }
            if let why {
                Text(why).font(Theme.Typo.caption).foregroundStyle(captionWarning ? Theme.warning : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var inlineRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            label.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            control.environment(\.settingRowTitle, title).fixedSize()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Keep a readable text column. At compact widths, a long menu gets its own line.
            Group {
                if keepsControlInline {
                    inlineRow
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: Theme.Space.m) {
                            label.frame(minWidth: 180, alignment: .leading)
                            Spacer(minLength: Theme.Space.s)
                            control.environment(\.settingRowTitle, title).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            label
                            HStack { Spacer(minLength: 0); control.environment(\.settingRowTitle, title).fixedSize() }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            if divider { Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, Theme.Space.m) }
        }
        .preference(key: SettingsRowTitles.self, value: [title])
    }
}

/// Green tick / amber dot status line.
struct StatusLabel: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Theme.positive : Theme.warning)
            Text(text).foregroundStyle(ok ? Color.secondary : Theme.warning)
        }
        .font(Theme.Typo.caption.weight(.medium))
    }
}

/// Pill tag ("raw", "snippet", app name…).
struct Tag: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text).font(Theme.Typo.footnote).lineLimit(1).help(text)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Space.xs).frame(height: 18)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Primary brand button: mint on indigo.
struct BrandButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typo.section)
            .foregroundStyle(prominent ? Theme.onMint : Color.primary)
            .padding(.horizontal, Theme.Space.m).frame(height: 30)
            .background(Capsule(style: .continuous).fill(prominent ? AnyShapeStyle(Theme.mintGradient) : AnyShapeStyle(Theme.inset)))
            .overlay(Capsule(style: .continuous).strokeBorder(prominent ? Color.white.opacity(0.35) : Theme.cardBorder, lineWidth: 0.75))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

enum Format {
    static func number(_ n: Int) -> String { n.formatted(.number) }
    static func duration(_ s: TimeInterval) -> String {
        if s < 60 { return "\(Int(s.rounded())) s" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m) min" }
        let h = Double(m) / 60
        return h < 10 ? String(format: "%.1f h", h) : "\(Int(h.rounded())) h"
    }
    static func clip(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "0:\(String(format: "%02d", t))" : "\(t / 60):\(String(format: "%02d", t % 60))"
    }
}

/// Brand switch: mint track when on. Drawn in SwiftUI so it looks the same everywhere.
struct BrandSwitchStyle: ToggleStyle {
    var small = false
    @Environment(\.settingRowTitle) private var rowTitle
    func makeBody(configuration: Configuration) -> some View {
        let w: CGFloat = small ? 30 : 38, h: CGFloat = small ? 18 : 22
        return HStack {
            // Labels are supplied by the surrounding row; keep the toggle’s named label out of layout.
            configuration.label.hidden().frame(width: 0, height: 0).accessibilityHidden(true)
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? AnyShapeStyle(Theme.mintGradient) : AnyShapeStyle(Color.secondary.opacity(0.28)))
                    Capsule().strokeBorder(configuration.isOn ? Color.white.opacity(0.3) : Theme.cardBorder, lineWidth: 0.5)
                    Circle().fill(.white).shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                        .padding(Theme.Space.hair)
                }
                .frame(width: w, height: h)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rowTitle)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

/// Fades decorative waves out at both ends.
extension View {
    func edgeFade() -> some View {
        mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                    .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                            startPoint: .leading, endPoint: .trailing))
    }
}

private struct SettingRowTitleKey: EnvironmentKey { static let defaultValue = "Setting" }
extension EnvironmentValues {
    var settingRowTitle: String {
        get { self[SettingRowTitleKey.self] }
        set { self[SettingRowTitleKey.self] = newValue }
    }
}

/// Preview verification collects the actual visible preference rows, including nested sections.
struct SettingsRowTitles: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

private struct SettingsViewportHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 700 }
extension EnvironmentValues {
    var settingsViewportHeight: CGFloat {
        get { self[SettingsViewportHeightKey.self] }
        set { self[SettingsViewportHeightKey.self] = newValue }
    }
}

private struct SetupBannerHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SetupBannerScroll: ViewModifier {
    let maxHeight: CGFloat
    @State private var naturalHeight: CGFloat = 0
    func body(content: Content) -> some View {
        ScrollView {
            content.frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.preference(key: SetupBannerHeight.self, value: g.size.height)
                })
        }
        .frame(height: min(naturalHeight > 0 ? naturalHeight : maxHeight, maxHeight - 2 * Theme.Space.s))
        .onPreferenceChange(SetupBannerHeight.self) { naturalHeight = $0 }
    }
}

/// A disclosure is a settings row: titles align with SettingRow; children share one indent.
struct SettingsDisclosureRow<Content: View>: View {
    let title: String
    let caption: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.Typo.bodyEmphasis)
                        Text(caption).font(Theme.Typo.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(Theme.Typo.chevron)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).padding(Theme.Space.m)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Theme.Space.m + Theme.Space.s)
                    .padding(.trailing, Theme.Space.m).padding(.bottom, Theme.Space.m)
            }
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, Theme.Space.m)
        }
    }
}
