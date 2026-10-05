import Testing
import Foundation
@testable import WisprLocalCore

struct InjectedInsertError: Error, LocalizedError { var errorDescription: String? { "injected" } }

/// SEC-2 (STRUCTURAL): a dictation that was refused (conflict / secure input / focus gate /
/// remote secure input) or not delivered (insert failed) leaves an OUTCOME-ONLY history record —
/// timestamp, outcome, app bundle ID, timings — and no troubleshooting audio.
/// SEC-14: everything holding text or audio is 0600 in a 0700 directory.
@MainActor @Suite(.serialized) struct RetentionTests {
    static let spoken = "Please open whisperflow, um, now."

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID().uuidString)", isDirectory: true)
    }

    static func recorder(_ dir: URL) -> DebugRecordingStore {
        DebugRecordingStore(directory: dir, limit: 20, isEnabled: { true })
    }

    static func expectOutcomeOnly(_ h: HistoryEntry?, _ outcome: HistoryEntry.Outcome,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        guard let h else { Issue.record("no history entry", sourceLocation: sourceLocation); return }
        #expect(h.outcome == outcome, sourceLocation: sourceLocation)
        #expect(h.raw.isEmpty && h.final.isEmpty, "text retained: \(h.raw) / \(h.final)", sourceLocation: sourceLocation)
        #expect(h.cleanupCandidate == nil && h.cleanupVerdict == nil && h.snippetTrigger == nil && h.join == nil,
                sourceLocation: sourceLocation)
        #expect(h.frontmostApp == "com.apple.TextEdit", sourceLocation: sourceLocation)
        #expect(h.recognisedWords, "word count (content-free) should survive", sourceLocation: sourceLocation)
        let json = String(decoding: (try? JSONEncoder().encode(h)) ?? Data(), as: UTF8.self)
        #expect(!json.localizedCaseInsensitiveContains("whisperflow") && !json.contains("Wispr Flow now"),
                "dictated words in the serialised entry: \(json)", sourceLocation: sourceLocation)
    }

    /// Runs `refuse` (sets up a refusal and dictates), then one normal control dictation; the
    /// refused one must be outcome-only with no audio, the control must keep both.
    func check(_ outcome: HistoryEntry.Outcome, keepsAudio: Bool = false, refuse: (PipelineEnv, DictationPipeline) async -> Void,
               restore: (PipelineEnv) -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.recorder(dir)
        let (e, p) = await makeEnv(text: Self.spoken, debugRecordings: store)
        await refuse(e, p)
        Self.expectOutcomeOnly(e.history.entries.last, outcome, sourceLocation: sourceLocation)
        #expect(e.inserter.inserted.isEmpty, sourceLocation: sourceLocation)
        // Control: same pipeline, normal dictation → content + audio kept.
        restore(e)
        _ = await p.process(samples: e.audio.samples, target: e.front)
        let ok = e.history.entries.last!
        #expect(ok.outcome == .inserted && ok.raw == Self.spoken && !ok.final.isEmpty, sourceLocation: sourceLocation)
        await p.flushDebugRecordings()   // the clip write is detached; wait for it deterministically
        #expect(store.recordings().count == (keepsAudio ? 2 : 1),
                keepsAudio ? "a failure keeps its audio (never its text)" : "a safety refusal keeps no audio",
                sourceLocation: sourceLocation)
    }

    @Test func captureInterruptionBelowMinimumDiscardsAudioAndText() async {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.recorder(dir)
        let (e, p) = await makeEnv(text: Self.spoken, debugRecordings: store)
        e.audio.samples = Array(e.audio.samples.prefix(3_199))
        p.handle(.startRecording)
        e.audio.interrupt()
        await p.drain()
        await p.flushDebugRecordings()
        let entry = e.history.entries.last
        #expect(entry?.outcome == .cancelled)
        #expect(entry?.note == "Microphone interrupted")
        #expect(entry?.outcomeLabel == "Microphone interrupted")
        let json = String(decoding: (try? JSONEncoder().encode(entry)) ?? Data(), as: UTF8.self)
        #expect(!json.contains(Self.spoken) && !json.localizedCaseInsensitiveContains("whisperflow"))
        #expect(entry?.raw.isEmpty == true && entry?.final.isEmpty == true)
        #expect(entry?.cleanupCandidate == nil && entry?.snippetTrigger == nil)
        #expect(store.recordings().isEmpty)
        #expect(e.inserter.inserted.isEmpty && e.transcriber.callCount == 0)
        #expect(e.notices == [PipelineNotice.captureInterrupted])
        #expect(p.status == .ready)
    }

    @Test func secureInputRefusalKeepsNoTextOrAudio() async {
        await check(.blockedBySecureInput, refuse: { e, p in
            p.handle(.startRecording)
            e.secure.active = true
            p.handle(.commitRecording)
            await p.drain()
            #expect(e.clipboard.strings.isEmpty)
        }, restore: { $0.secure.active = false })
    }

    @Test func focusChangeRefusalKeepsNoTextOrAudio() async {
        await check(.focusChanged, refuse: { e, p in
            p.handle(.startRecording)
            e.front = FrontmostApp(pid: 77, bundleID: "com.tinyspeck.slackmacgap")
            p.handle(.commitRecording)
            await p.drain()
            // The user's recovery copy still happens; only retention is refused.
            #expect(e.clipboard.strings == ["Please open Wispr Flow now."])
        }, restore: { $0.front = FrontmostApp(pid: 42, bundleID: "com.apple.TextEdit") })
    }

    @Test func conflictRefusalKeepsNoTextOrAudio() async {
        await check(.blockedByConflict, refuse: { e, p in
            e.apps = [PipelineTests.wispr]
            _ = await p.process(samples: e.audio.samples, target: e.front)
        }, restore: { $0.apps = [] })
    }

    /// Not a safety refusal: the app refused the paste. No text, but the audio is kept to replay.
    @Test func failedInsertKeepsAudioButNoText() async {
        await check(.insertFailed, keepsAudio: true, refuse: { e, p in
            e.inserter.failWith = InjectedInsertError()
            _ = await p.process(samples: e.audio.samples, target: e.front)
        }, restore: { $0.inserter.failWith = nil })
    }

    @Test func remoteSecureInputRefusalKeepsNoTextOrAudio() async {
        await check(.blockedByRemoteSecureInput, refuse: { e, p in
            e.inserter.failWith = RemoteInsertionError.remoteSecureInput("Studio")
            _ = await p.process(samples: e.audio.samples, target: e.front)
            #expect(e.notices.contains(PipelineNotice.remoteSecureInput))
        }, restore: { $0.inserter.failWith = nil })
    }

    /// Exhaustive retention table (HistoryStore `mayKeepDebugAudio` doc): only `.inserted` carries
    /// text; every outcome keeps audio EXCEPT the four SEC-2 safety refusals.
    @Test func outcomePolicyTable() {
        let table: [(HistoryEntry.Outcome, text: Bool, audio: Bool)] = [
            (.inserted, true, true),
            (.noSpeech, false, true), (.emptyAfterCleanup, false, true), (.noTextRecognised, false, true),
            (.transcriptionTimedOut, false, true), (.transcriptionFailed, false, true), (.insertFailed, false, true),
            (.blockedBySecureInput, false, false), (.blockedByRemoteSecureInput, false, false),
            (.focusChanged, false, false), (.blockedByConflict, false, false),
        ]
        for (o, text, audio) in table {
            #expect(o.retainsContent == text, "\(o) text")
            #expect(o.mayKeepDebugAudio == audio, "\(o) audio")
            #expect(o.isSafetyRefusal == !audio, "\(o) refusal")
        }
    }

    // MARK: SEC-14 permissions

    static func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    @Test func historyFileIsOwnerOnly() throws {
        let dir = Self.tempDir().appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = HistoryStore(directory: dir)
        s.append(HistoryEntry(outcome: .noSpeech))
        s.append(HistoryEntry(outcome: .noSpeech))   // append path (file exists)
        s.flush()
        #expect(Self.mode(dir) == 0o700)
        #expect(Self.mode(s.fileURL) == 0o600)
        try s.replaceAll(with: [])
        #expect(Self.mode(s.fileURL) == 0o600)
    }

    @Test func historyFileFromOlderBuildIsTightened() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let s = HistoryStore(directory: dir)
        s.append(HistoryEntry(outcome: .noSpeech)); s.flush()
        #expect(Self.mode(url) == 0o600)
    }

    @Test func dictionaryFileIsOwnerOnly() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dictionary.json")
        let d = DictionaryStore(url: url)
        try d.update(UserDictionary(vocabulary: ["Kubernetes"]))
        #expect(Self.mode(dir) == 0o700)
        #expect(Self.mode(url) == 0o600)
    }

    @Test func debugRecordingsAreOwnerOnly() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Self.recorder(dir)
        let wav = try #require(store.save(samples: [Float](repeating: 0.1, count: 1600), entry: HistoryEntry(outcome: .inserted)))
        #expect(Self.mode(dir) == 0o700)
        #expect(Self.mode(wav) == 0o600)
        #expect(Self.mode(wav.deletingPathExtension().appendingPathExtension("json")) == 0o600)
    }
}
