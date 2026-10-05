import Testing
import Foundation
@testable import WisprLocalCore

/// One Settings structure (`SettingsSection`): sentence-case titles, and no copy anywhere that
/// points at a section that doesn't exist (a stale Conveniences path after it was merged away).
@Suite struct SettingsStructureTests {
    static var repoRoot: URL { HelpContentTests.repoRoot }

    /// History › Fix a Word: the copy names the Dictionary (not "Words"), the button says what it
    /// does, and the word chips are not drawn as `Capsule` strokes (whose ends rendered clipped).
    @Test func fixAWordSheetCopyAndChips() throws {
        let url = Self.repoRoot.appendingPathComponent("WisprLocal/App/Sources/WisprLocal/FixWordSheet.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("adds the spelling to your Dictionary"))
        #expect(text.contains("static let addTitle = \"Add to Dictionary\"") && text.contains("Button(Self.addTitle"))
        #expect(!text.contains("Button(\"Add Fix\""))
        #expect(!text.contains("Capsule().strokeBorder") && !text.contains("Capsule().fill"))
        #expect(!text.contains("ScrollView {\n                FlowLayout"), "the words size to fit; only a long dictation scrolls")
    }

    @Test func orderAndSentenceCase() {
        #expect(SettingsSection.allCases == [.general, .microphone, .writing, .privacy, .remote])
        #expect(SettingsSection.allCases.map(\.title) == ["General", "Microphone", "Writing", "Privacy", "Remote Macs"])
        let properNouns: Set<String> = ["Macs"]
        for s in SettingsSection.allCases {
            let words = s.title.split(separator: " ").map(String.init)
            #expect(words.first?.first?.isUppercase == true, "\(s.title)")
            for w in words.dropFirst() where !properNouns.contains(w) {
                #expect(w == w.lowercased(), "Settings titles are sentence case: \(s.title)")
            }
            #expect(!s.symbol.isEmpty)
        }
    }

    /// DESIGN.md › Voice and tone: row titles in sentence case, buttons in Title Case. Every literal
    /// `Button("…")` in the Settings page, its sections and its sheets is Title Case (small words
    /// lower case after the first word).
    @Test func settingsButtonsAreTitleCase() throws {
        let app = Self.repoRoot.appendingPathComponent("WisprLocal/App/Sources/WisprLocal")
        var files = ["SettingsView.swift", "RemoteSettingsView.swift", "PermissionHealthView.swift", "MicCheckView.swift"]
            .map { app.appendingPathComponent($0) }
        files += try FileManager.default.contentsOfDirectory(at: app.appendingPathComponent("Settings"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let small: Set<String> = ["a", "an", "the", "and", "or", "to", "for", "of", "in", "on", "at", "by"]
        let regex = try NSRegularExpression(pattern: #"Button\("([^"\\]+)""#)
        var titles: [String] = []
        var bad: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let title = String(text[r])
                titles.append(title)
                for (i, w) in title.split(separator: " ").enumerated() {
                    guard let c = w.first, c.isLetter else { continue }
                    if i > 0, small.contains(w.lowercased()) { if c.isUppercase { bad.append("\(url.lastPathComponent): \(title)") }; continue }
                    if !c.isUppercase { bad.append("\(url.lastPathComponent): \(title)") }
                }
            }
        }
        #expect(titles.contains("Test…") && !titles.contains("Hide for 1 Hour"))
        #expect(bad.isEmpty, "Settings buttons are Title Case:\n\(bad.joined(separator: "\n"))")
    }

    @Test func pinnedTabsAndConditionalBanner() throws {
        let root = Self.repoRoot.appendingPathComponent("WisprLocal/App/Sources/WisprLocal")
        let view = try String(contentsOf: root.appendingPathComponent("SettingsView.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("AppModel.swift"), encoding: .utf8)
        let components = try String(contentsOf: root.appendingPathComponent("Components.swift"), encoding: .utf8)
        #expect(view.contains(".pickerStyle(.segmented)"))
        #expect(view.contains("selection: $model.settingsTab"))
        #expect(view.contains("pinnedHeader: AnyView(header)"))
        #expect(view.contains("if !model.setupIssues.isEmpty { SetupBanner(model: model) }"))
        #expect(!view.contains("AboutSettings") && !view.contains("ScrollViewReader"))
        #expect(model.contains("defaults.set(settingsTab.rawValue, forKey: Self.settingsTabKey)"))
        #expect(model.contains("SetupIssue.resolve("))
        #expect(components.contains(".accessibilityLabel(rowTitle)"))
        #expect(!components.contains(".onTapGesture { configuration.isOn.toggle() }"))
    }

    /// The app target cannot be imported here. Scan only row declaration titles within
    /// struct boundaries (not captions/layout whitespace). Explicit conditional title sets
    /// describe defaults: Flow absent, noise reduction and AI formatting off, no paired receiver.
    @Test func exactDefaultPreferenceRows() throws {
        let root = Self.repoRoot.appendingPathComponent("WisprLocal/App/Sources/WisprLocal")
        func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func block(_ text: String, _ start: String, _ end: String) throws -> String {
            let a = try #require(text.range(of: start)).lowerBound
            let b = try #require(text.range(of: end, range: a..<text.endIndex)).lowerBound
            return String(text[a..<b])
        }
        // Minimal declaration prefix; computed titles are also captured so additions fail.
        func titles(_ text: String, excluding conditional: Set<String> = []) throws -> [String] {
            let regex = try NSRegularExpression(pattern: #"SettingRow\(title: ([^,\n]+)"#)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                guard let r = Range($0.range(at: 1), in: text) else { return nil }
                let title = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return conditional.contains(title) ? nil : title
            }
        }
        let view = try read("SettingsView.swift")
        let controls = try read("Settings/ControlsSettingsRows.swift")
        let general = try titles(block(view, "struct GeneralSettings", "struct PresetTile"), excluding: ["WisprFlowCopy.differentShortcut"])
            + titles(block(controls, "struct ControlsRows", "struct HistoryRetentionRow"))
            + ["Recording pill position"] // custom tile row emits its own preference
        #expect(general == ["Keep macOS from also reacting to 🌐", "Mouse button", "Start and stop sounds", "Shift while releasing 🌐 presses Return", "Recording pill position"])
        let microphone = try titles(block(view, "struct MicrophoneSettings", "struct PrivacySettings"), excluding: ["↳ Mic Mode"])
        #expect(microphone == ["Microphone", "Noise reduction", "Microphone readiness", "Speech model"])
        let writing = try titles(block(read("Settings/WritingSettingsSection.swift"), "struct WritingSettingsSection", "private func overrideRow"), excluding: ["Apple Intelligence"])
            + titles(read("Settings/DictionarySettingsSection.swift"))
        #expect(writing == ["AI formatting", "Fix “actually” corrections", "Per-app styles", "Learn words from my corrections", "Names and terms near your cursor"])
        let privacy = try titles(block(controls, "struct HistoryRetentionRow", "struct KeyHint"))
            + titles(block(view, "struct PrivacySettings", "struct MicPicker"))
        #expect(privacy == ["Keep history", "AppSettings.keepRecordingsLabel", "History folder", "Greet me by name on Home"])
        let remote = try read("RemoteSettingsView.swift")
        // Match only the guard and picker title; layout whitespace is immaterial.
        let pairedPicker = try NSRegularExpression(pattern: #"if !store.receivers.isEmpty \{\s*Picker\("Default receiver""#)
        #expect(pairedPicker.numberOfMatches(in: remote, range: NSRange(remote.startIndex..., in: remote)) == 1)
        let preference = try NSRegularExpression(pattern: #"value: \["([^"\\]+)"\]"#)
        let remoteRows = preference.matches(in: remote, range: NSRange(remote.startIndex..., in: remote)).compactMap {
            Range($0.range(at: 1), in: remote).map { String(remote[$0]) }
        }.filter { $0 != "Default receiver" } // absent at defaults, guarded above
        #expect(remoteRows == ["Typing fallback"])
        let counts: [Int] = [general.count, microphone.count, writing.count, privacy.count, remoteRows.count]
        #expect(counts == [5, 4, 5, 4, 1])
    }

    /// Every settings path in user-facing copy and in code comments names a real section.
    @Test func everyReferenceNamesARealSection() throws {
        var texts: [(String, String)] = []
        let root = Self.repoRoot
        for path in ["readme.md", "WisprLocal/docs/DESIGN.md"] {
            texts.append((path, try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)))
        }
        // The CHANGELOG's released sections are history; only "Unreleased" must match today's app.
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let unreleased = changelog.components(separatedBy: "\n## ").first { $0.hasPrefix("Unreleased") } ?? ""
        texts.append(("CHANGELOG.md (Unreleased)", unreleased))
        let sources = root.appendingPathComponent("WisprLocal/App/Sources")
        let e = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "SettingsSection.swift" else { continue }
            texts.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(texts.count > 50)
        let titles = SettingsSection.allCases.map(\.title)
        var bad: [String] = []
        for (name, text) in texts {
            var rest = text[...]
            while let r = rest.range(of: "Settings \u{203A} ") {
                let before = text[text.startIndex..<r.lowerBound].suffix(7)
                let after = rest[r.upperBound...]
                rest = after
                if before.hasSuffix("System ") || before.hasSuffix("macOS ") { continue }  // the Mac's own settings
                let ok = titles.contains { t in
                    guard after.hasPrefix(t) else { return false }
                    let next = after.dropFirst(t.count).first
                    return next.map { !$0.isLetter } ?? true
                }
                if !ok { bad.append("\(name): Settings \u{203A} \(after.prefix(24))") }
            }
        }
        #expect(bad.isEmpty, "stale Settings references:\n\(bad.joined(separator: "\n"))")
    }
}
