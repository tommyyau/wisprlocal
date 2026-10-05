#if DEBUG
import SwiftUI
import WisprLocalCore

/// DEBUG preview only: an NSMenu can't be snapshotted offscreen, so this draws a mock of the
/// menu-bar menu from the SAME `MenuModel.entries` that `MenuContent` renders, styled like a
/// macOS 26 menu. Clearly labelled as a mock in the image.
struct MenuMock: View {
    let caption: String
    let entries: [MenuEntry]
    let icon: MenuBarIconState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MOCK (SwiftUI, from MenuModel.entries) · \(caption)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .trailing, spacing: 6) {
                menuBar
                menu
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.86))
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi").font(.system(size: 13))
            glyph
            Text("Sat 3 Oct  09:41").font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, Theme.Space.s).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.well).fill(.primary.opacity(0.06)))
    }

    @ViewBuilder private var glyph: some View {
        if let img = Self.glyphImage(icon) {
            Image(nsImage: img).renderingMode(.template).foregroundStyle(.primary)
                .padding(.horizontal, Theme.Space.tight).padding(.vertical, Theme.Space.hair)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.tiny).fill(.primary.opacity(0.14)))
        }
    }

    /// Where the glyph PNGs live (the preview binary isn't bundled): App/Resources.
    static var resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources")

    /// The real glyph PNG from Resources.
    static func glyphImage(_ s: MenuBarIconState) -> NSImage? {
        guard let img = NSImage(contentsOf: resources.appendingPathComponent("\(s.resourceName)@2x.png")) else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in row(e) }
        }
        .padding(Theme.Space.tight)
        .frame(width: max(CGFloat(MenuModel.noisyRoomSubtitle.count) * 6.2 + 64,
                          CGFloat(entries.map { $0.title.count }.max() ?? 0) * 7.1 + 64), alignment: .leading)
        // Solid stand-in for the menu's material (offscreen renders can't sample a backdrop).
        .background(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
            .fill(scheme == .dark ? Color(white: 0.21) : Color(white: 0.975)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
    }

    @ViewBuilder private func row(_ e: MenuEntry) -> some View {
        switch e {
        case .separator:
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, Theme.Space.snug).padding(.vertical, Theme.Space.tight)
        case .attention(let a):
            line(e.title, enabled: a.action != nil)
        case .noisyRoom(let checked):
            line(e.title, subtitle: MenuModel.noisyRoomSubtitle, check: checked)
        case .help:
            line(e.title, submenu: true)
        default:
            line(e.title, key: e.keyEquivalent)
        }
    }

    private func line(_ title: String, subtitle: String? = nil, enabled: Bool = true, check: Bool = false, key: Character? = nil,
                      submenu: Bool = false) -> some View {
        HStack(spacing: 0) {
            Text(check ? "✓" : "").font(.system(size: 13, weight: .semibold)).frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 24)
            if let key { Text("⌘\(String(key).uppercased())").font(.system(size: 13)).foregroundStyle(.secondary) }
            if submenu { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .foregroundStyle(enabled ? .primary : .tertiary)
        .padding(.horizontal, Theme.Space.tight).frame(height: subtitle == nil ? 22 : 40)
    }
}
#endif
