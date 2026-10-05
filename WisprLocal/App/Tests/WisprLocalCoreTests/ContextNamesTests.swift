import Testing
import Foundation
import ApplicationServices
@testable import WisprLocalCore

/// Spy reader: records every read so the tests can prove what was (not) read. Called off the
/// main actor, so it locks.
final class SpyContextReader: ContextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _source: ContextSource? = ContextSource(fieldText: "Hi Shaun, the getUserById call in HistoryStore fails for @sam_lee. There is a fix.",
                                                        windowTitle: "Re: Kubernetes rollout — Priya Raman")
    private var _reads: [(pid: Int32, bundleID: String?, mail: Bool, onMain: Bool)] = []
    var source: ContextSource? {
        get { lock.withLock { _source } }
        set { lock.withLock { _source = newValue } }
    }
    var reads: [(pid: Int32, bundleID: String?, mail: Bool, onMain: Bool)] { lock.withLock { _reads } }
    func read(pid: Int32, bundleID: String?, includeMailNames: Bool) -> ContextSource? {
        let main = Thread.isMainThread
        return lock.withLock {
            _reads.append((pid, bundleID, includeMailNames, main))
            return _source
        }
    }
}

@MainActor func contextSettings(enabled: Bool = true) -> SmartDictionarySettings {
    let s = SmartDictionarySettings(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
    s.contextNamesEnabled = enabled
    return s
}

@MainActor @Suite struct ContextNamesTests {
    @Test func extractsNamesIdentifiersAndHandles() {
        let c = ContextExtractor.candidates(from: ["Hi Shaun's team, getUserById and user_id for @sam_lee. There NASA iPhone http x"])
        let byKind = Dictionary(grouping: c, by: \.kind).mapValues { $0.map(\.surface) }
        #expect(byKind[.name] == ["Shaun", "NASA"])
        #expect(byKind[.identifier] == ["getUserById", "user_id", "iPhone"])
        #expect(byKind[.handle] == ["@sam_lee"])
        #expect(!c.contains { $0.surface == "There" || $0.surface == "Hi" })    // sentence-start common words
    }

    @Test func extractionIsCappedAndDeduplicated() {
        let text = (0..<1_000).map { "Name\($0)x Shaun" }.joined(separator: " ")
        let c = ContextExtractor.candidates(from: [text])
        #expect(c.count == ContextExtractor.maxCandidates)
        #expect(c.filter { $0.surface == "Shaun" }.count == 1)
    }

    @Test func offByDefaultAndNothingIsReadWhenOff() async {
        let fresh = SmartDictionarySettings(defaults: UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!)
        #expect(fresh.contextNamesEnabled == false)
        #expect(fresh.learnMode == .suggest)
        let spy = SpyContextReader()
        let p = ContextProvider(settings: fresh, reader: spy, secureInput: FakeSecureInput(), appCategory: { _ in nil })
        #expect(await p.snapshot(for: FrontmostApp(pid: 5, bundleID: "com.apple.mail")) == nil)
        #expect(spy.reads.isEmpty)
    }

    @Test func readsAndExtractsWhenOn() async throws {
        let spy = SpyContextReader()
        let p = ContextProvider(settings: contextSettings(), reader: spy, secureInput: FakeSecureInput(), appCategory: { _ in nil })
        let snap = try #require(await p.snapshot(for: FrontmostApp(pid: 5, bundleID: "com.apple.mail")))
        #expect(spy.reads.count == 1 && spy.reads[0].mail)                         // Mail: To/From names too
        #expect(!spy.reads[0].onMain)                                              // P1: AX off the main actor
        #expect(snap.candidates.contains(ContextCandidate("Shaun", kind: .name)))
        #expect(snap.candidates.contains(ContextCandidate("Priya", kind: .name)))  // window title
        #expect(!snap.isCodeApp)
        _ = await p.snapshot(for: FrontmostApp(pid: 6, bundleID: "com.apple.dt.Xcode"))
        #expect(spy.reads.last?.mail == false)
    }

    @Test(arguments: ContextPolicy.defaultDenylist) func denylistedAppsAreNeverRead(_ bundleID: String) async {
        let spy = SpyContextReader()
        let p = ContextProvider(settings: contextSettings(), reader: spy, secureInput: FakeSecureInput(), appCategory: { _ in nil })
        #expect(await p.snapshot(for: FrontmostApp(pid: 9, bundleID: bundleID)) == nil)
        #expect(spy.reads.isEmpty)
    }

    @Test func passwordManagersAndKeychainAreDeniedByDefault() {
        for id in ["com.1password.1password", "com.apple.keychainaccess", "com.apple.Passwords", "com.bitwarden.desktop"] {
            #expect(ContextPolicy.defaultDenylist.contains(id), "\(id)")
        }
    }

    @Test func bankingAppsAreNeverReadEvenIfNotListed() async {
        let spy = SpyContextReader()
        let p = ContextProvider(settings: contextSettings(), reader: spy, secureInput: FakeSecureInput(),
                                appCategory: { _ in ContextPolicy.financeCategory })
        #expect(await p.snapshot(for: FrontmostApp(pid: 9, bundleID: "com.example.mybank")) == nil)
        #expect(spy.reads.isEmpty)
    }

    @Test func theDenylistIsEditable() async {
        let s = contextSettings()
        let spy = SpyContextReader()
        let p = ContextProvider(settings: s, reader: spy, secureInput: FakeSecureInput(), appCategory: { _ in nil })
        #expect(s.deny("com.example.private"))
        #expect(!s.deny("com.example.private"))
        #expect(await p.snapshot(for: FrontmostApp(pid: 9, bundleID: "com.example.private")) == nil)
        s.allow("com.1password.1password")
        #expect(await p.snapshot(for: FrontmostApp(pid: 9, bundleID: "com.1password.1password")) != nil)
        s.resetDenylist()
        #expect(s.contextDenylist == ContextPolicy.defaultDenylist)
    }

    @Test func secureInputMeansNoRead() async {
        let spy = SpyContextReader()
        let secure = FakeSecureInput(); secure.active = true
        let p = ContextProvider(settings: contextSettings(), reader: spy, secureInput: secure, appCategory: { _ in nil })
        #expect(await p.snapshot(for: FrontmostApp(pid: 5, bundleID: "com.apple.TextEdit")) == nil)
        #expect(spy.reads.isEmpty)
    }

    @Test func secureOrUnreadableFieldsGiveNothing() async {
        let spy = SpyContextReader()
        spy.source = nil                               // the AX reader returns nil for AXSecureTextField
        let p = ContextProvider(settings: contextSettings(), reader: spy, secureInput: FakeSecureInput(), appCategory: { _ in nil })
        #expect(await p.snapshot(for: FrontmostApp(pid: 5, bundleID: "com.apple.TextEdit")) == nil)
    }

    @Test func urlFieldsAreRecognised() {
        #expect(ContextPolicy.isURLField(identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", description: nil, value: "x"))
        #expect(ContextPolicy.isURLField(identifier: nil, description: "Address and search bar", value: nil))
        #expect(ContextPolicy.isURLField(identifier: nil, description: nil, value: "www.example.com/path"))
        #expect(ContextPolicy.isURLField(identifier: nil, description: nil, value: "ftp" + "://example.com"))
        #expect(!ContextPolicy.isURLField(identifier: nil, description: "Message body", value: "Hi Shaun, see example.com today"))
    }

    @Test func codeAppsAreKnown() {
        #expect(ContextPolicy.isCodeApp("com.apple.dt.Xcode"))
        #expect(ContextPolicy.isCodeApp("com.jetbrains.whatever"))
        #expect(!ContextPolicy.isCodeApp("com.apple.mail"))
        #expect(!ContextPolicy.isCodeApp(nil))
    }
}

/// Pipeline integration: context names are used for ONE dictation and never persisted.
@MainActor @Suite struct ContextNamesPipelineTests {
    final class FixedProvider: ContextProviding {
        var snapshot: ContextSnapshot?
        var calls = 0
        init(_ s: ContextSnapshot?) { snapshot = s }
        func snapshot(for target: FrontmostApp) -> ContextSnapshot? { calls += 1; return snapshot }
    }

    static let context = ContextSnapshot(candidates: [ContextCandidate("Shaun", kind: .name), ContextCandidate("Priya", kind: .name),
                                                      ContextCandidate("getUserById", kind: .identifier)], isCodeApp: false)

    @Test func snapsAndRecordsOnlyACount() async throws {
        let dict = tempDictionary()
        let before = try Data(contentsOf: dict.url)
        let (e, p) = await makeEnv(text: "Thanks Sean, call get user by id.", dictionary: dict)
        let provider = FixedProvider(Self.context)
        p.contextProvider = provider
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(provider.calls == 1)
        #expect(e.inserter.inserted == ["Thanks Shaun, call get user by id."])   // not a code app: identifier untouched
        let h = try #require(e.history.entries.last)
        #expect(h.contextSnaps == 1)
        // In memory only: nothing from the context that wasn't dictated reaches History, the
        // dictionary file, or a learning file.
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let json = String(decoding: try enc.encode(h), as: UTF8.self)
        #expect(!json.contains("Priya") && !json.contains("getUserById"))
        #expect(try Data(contentsOf: dict.url) == before)
        #expect(!FileManager.default.fileExists(atPath: dict.url.deletingLastPathComponent().appendingPathComponent("learning.json").path))
    }

    @Test func noProviderMeansNoCountAndVocabularyStillSnaps() async throws {
        let dict = tempDictionary()
        var d = dict.dictionary; d.addTerm("Kubernetes"); try dict.update(d)
        let (e, p) = await makeEnv(text: "We deploy on kuber netties.", dictionary: dict)
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["We deploy on Kubernetes."])
        #expect(e.history.entries.last?.contextSnaps == nil)
    }

    @Test func cancelledRecordingDropsTheContext() async {
        let (e, p) = await makeEnv(text: "Thanks Sean.")
        let provider = FixedProvider(Self.context)
        p.contextProvider = provider
        p.handle(.startRecording)
        p.handle(.cancelRecording)
        p.contextProvider = nil
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(e.inserter.inserted == ["Thanks Sean."])
    }

    @Test func refusedDictationsKeepNoContextCount() async {
        let (e, p) = await makeEnv(text: "Thanks Sean.")
        p.contextProvider = FixedProvider(Self.context)
        p.handle(.startRecording)
        e.front = FrontmostApp(pid: 77, bundleID: "com.other")
        p.handle(.commitRecording)
        await p.drain()
        let h = e.history.entries.last!
        #expect(h.outcome == .focusChanged)
        #expect(h.final.isEmpty && h.raw.isEmpty)
    }

    @Test func successfulPasteReportsTheInsertionForWatching() async {
        let (e, p) = await makeEnv(text: "We deploy today.")
        var got: [InsertedDictation] = []
        p.onInserted = { got.append($0) }
        p.handle(.startRecording)
        p.handle(.commitRecording)
        await p.drain()
        #expect(got.count == 1)
        #expect(got.first?.pid == 42)
        #expect(got.first?.text == "We deploy today.")
        #expect(got.first?.axReadable == false)        // no verified paste report from the fake inserter
        #expect(e.history.entries.count == 1)
    }
}

@Suite struct ContextFieldExclusionTests {

    @Test func urlFieldNeverInvokesTextRead() {
        var reads = 0
        let result = AXContextReader.readAllowedField(identifier: "URL", description: "Address bar") {
            reads += 1; return "Private text"
        }
        #expect(result == nil)
        #expect(reads == 0)
    }

}

@Suite struct ContextReaderPrivacyTests {
    @Test(arguments: ["https://PrivateName.example/path", "www.PrivateName.example/path"])
    func unlabeledURLValueIsExcludedByRead(_ value: String) throws {
        let reader = AXContextReader(access: .init(
            trusted: { true },
            element: { _, attr in attr == kAXFocusedUIElementAttribute ? AXUIElementCreateApplication(0) : nil },
            string: { _, attr in attr == kAXDescriptionAttribute ? "Search box" : nil },
            text: { _ in value }))
        let snapshot = try #require(reader.read(pid: 0, bundleID: nil, includeMailNames: false))
        #expect(snapshot.fieldText == nil)
    }

    @Test func labeledURLIsExcludedBeforeRead() {
        let reader = AXContextReader(access: .init(
            trusted: { true },
            element: { _, attr in attr == kAXFocusedUIElementAttribute ? AXUIElementCreateApplication(0) : nil },
            string: { _, attr in attr == kAXIdentifierAttribute ? "URL" : nil },
            text: { _ in Issue.record("URL metadata must prevent the text read"); return "PrivateName" }))
        #expect(reader.read(pid: 0, bundleID: nil, includeMailNames: false) == nil)
    }
}
