import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WisprLocalCore

/// Settings › Writing: how the words are written. AI formatting, the per-app styles (a style
/// per kind of app with a live example, plus per-app overrides) and the opt-in "Fix quick
/// corrections" (backtrack). In pipeline order: cleanup, then backtrack, then the style.
struct WritingSettingsSection: View {
    let model: AppModel
    @Bindable var store: StyleSettingsStore

    var expanded = false
    @State private var stylesExpanded = false

    /// The `--ui-preview` harness has no controller; it gets a throwaway store.
    @MainActor static let previewStore = StyleSettingsStore(defaults: UserDefaults(suiteName: "wisprlocal.preview.styles") ?? .standard)

    /// What the live example starts from: an unpunctuated, lowercase phrase.
    static let exampleSpoken = "see you at 3"

    var body: some View {
        let s = model.settings
        let avail = model.cleanupAvailability
        let config = store.configuration
        SettingsGroup(section: .writing,
                      footer: "Always on: fillers go, spacing and capitals fixed, instantly. English only.") {
            SettingRow(title: "AI formatting",
                       why: "Apple Intelligence: punctuation (up to 1.5 s); spoken lists use it even when off.",
                       info: .aiFormatting) {
                Toggle("", isOn: Binding(get: { s.aiCleanupEnabled }, set: { model.setAIFormatting($0) }))
                    .toggleStyle(BrandSwitchStyle()).labelsHidden()
            }
            if s.aiCleanupEnabled {
                SettingRow(title: "Apple Intelligence", why: avail.isAvailable ? "Ready, and running on-device." : avail.label) {
                    StatusLabel(ok: avail.isAvailable, text: avail.isAvailable ? "Ready" : "Unavailable")
                }
            }
            SettingRow(title: "Fix “actually” corrections",
                       why: "“At 2, actually 3” becomes “At 3”. Undo from the pill.",
                       info: .backtrack) {
                Toggle("", isOn: $store.backtrackEnabled).toggleStyle(BrandSwitchStyle()).labelsHidden()
            }
            SettingRow(title: "Per-app styles", why: "Formal for email and docs, Casual for chat, Code for editors.", divider: config.enabled, info: .styles) {
                Toggle("", isOn: Binding(get: { store.configuration.enabled }, set: { store.configuration.enabled = $0 }))
                    .toggleStyle(BrandSwitchStyle()).labelsHidden()
            }
            if config.enabled {
                SettingsDisclosureRow(title: "Customise styles", caption: "Choose a style for each kind of app or a particular app.", expanded: $stylesExpanded) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(AppCategory.allCases, id: \.self) { c in
                            HStack {
                                Text(c.title).font(Theme.Typo.caption)
                                Spacer(minLength: 0)
                                ChoiceMenu(selection: config.style(for: c), options: WritingStyle.allCases,
                                           title: \.title, label: c.title + " style", width: 140) { store.setStyle($0, for: c) }
                            }
                        }
                    }
                    Text(Self.legend)
                        .font(Theme.Typo.caption).foregroundStyle(.secondary)
                    ForEach(config.appOverrides.keys.sorted(), id: \.self) { id in
                        overrideRow(id, style: config.appOverrides[id] ?? .formal)
                    }
                    Button("Choose App…") { chooseApp() }.controlSize(.small)
                }

            }
            DictionarySettingsSection(model: model, expanded: expanded)
        }
        .onAppear { stylesExpanded = expanded }
    }

    private func overrideRow(_ bundleID: String, style: WritingStyle) -> some View {
        let app = AppIdentity.lookup(bundleID)
        return HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(Theme.Typo.bodyEmphasis)
                Text(Self.example(style)).font(Theme.Typo.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: Theme.Space.xs) {
                stylePicker(style, label: app.name + " style") { store.setOverride($0, forBundleID: bundleID) }
                Button { store.setOverride(nil, forBundleID: bundleID) } label: {
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                    .help("Use the style for \(AppCategoryMap.category(for: bundleID).title) again")
                    .accessibilityLabel("Remove the style for \(app.name)")
            }
        }
    }

    private func stylePicker(_ current: WritingStyle, label: String, set: @escaping (WritingStyle) -> Void) -> some View {
        ChoiceMenu(selection: current, options: WritingStyle.allCases, title: \.title, label: label, width: 140, choose: set)
    }

    /// “see you at 3” → “See you at 3.” — computed by the real style, so it is always true.
    static func example(_ s: WritingStyle) -> String {
        "\(s.summary) “\(exampleSpoken)” → “\(s.apply(WritingStyle.formal.apply(exampleSpoken, names: FixedNames()), names: FixedNames()))”"
    }

    /// One line explains the three default styles using the same computed examples.
    static var legend: String {
        [WritingStyle.formal, .casual, .code].map { style in
            style.title + " " + (example(style).components(separatedBy: " → ").last ?? "")
        }.joined(separator: " · ")
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        let current = store.configuration.style(forBundleID: id) ?? .formal
        store.setOverride(current, forBundleID: id)
    }
}
