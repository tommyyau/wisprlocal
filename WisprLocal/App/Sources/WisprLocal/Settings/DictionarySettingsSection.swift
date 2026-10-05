import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WisprLocalCore

/// Settings › Writing: the way to the Dictionary page, learning from corrections
/// and (opt-in) names and terms near the cursor.
struct DictionarySettingsSection: View {
    let model: AppModel
    var expanded = false
    /// Preview harness: a throwaway store, so previews never touch real settings.
    private static let previewSettings = SmartDictionarySettings(defaults: UserDefaults(suiteName: "wisprlocal.preview.smartDictionary") ?? .standard)
    private var settings: SmartDictionarySettings { model.live?.smart.settings ?? Self.previewSettings }

    var body: some View {
        let s = settings
        VStack(spacing: 0) {
            SettingRow(title: "Learn words from my corrections",
                       why: learningCaption(s.learnMode),
                       info: .learnCorrections) {
                ChoiceMenu(selection: s.learnMode, options: LearnMode.allCases, title: \.label, label: "Learn words from my corrections", width: 160) { s.learnMode = $0 }
            }
            SettingRow(title: "Names and terms near your cursor",
                       why: "Reads the text around your cursor when you start, forgets it when you finish.",
                       divider: true, info: .contextNames) {
                Toggle("", isOn: Binding(get: { s.contextNamesEnabled }, set: { s.contextNamesEnabled = $0 }))
                    .toggleStyle(BrandSwitchStyle()).labelsHidden()
            }
            ExcludedAppsRow(settings: s, startExpanded: expanded)
        }
    }
    private func learningCaption(_ mode: LearnMode) -> String {
        switch mode {
        case .suggest: "Asks before remembering a spelling you fixed."
        case .automatic: "Remembers spellings you fix without asking."
        case .off: "Never watches the field after a dictation."
        }
    }
}

/// "Never read these apps": the editable denylist as removable chips, plus Add App… and Reset.
private struct ExcludedAppsRow: View {
    let settings: SmartDictionarySettings
    var startExpanded = false
    @State private var expanded = false

    var body: some View {
        let names = Dictionary(settings.contextDenylist.map { (Self.displayName($0), $0) }, uniquingKeysWith: { a, _ in a })
        SettingsDisclosureRow(title: "Apps never read (\(settings.contextDenylist.count))",
                              caption: "Password managers and Keychain Access to start with. Apps in macOS's Finance category are always skipped.",
                              expanded: $expanded) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ChipFlow(items: names.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) { name in
                    if let id = names[name] { settings.allow(id) }
                }
                HStack(spacing: Theme.Space.xs) {
                    Button("Add App…", action: addApp).controlSize(.small)
                    Button("Reset to Defaults") { settings.resetDenylist() }.controlSize(.small)
                        .disabled(settings.contextDenylist == ContextPolicy.defaultDenylist)
                }
            }
        }.onAppear { expanded = startExpanded }
    }

    /// The installed app's name, else its bundle id.
    static func displayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Never Read"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { settings.deny(id) } }
    }
}
