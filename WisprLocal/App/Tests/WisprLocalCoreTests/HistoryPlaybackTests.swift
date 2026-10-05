import Testing
import Foundation
import Synchronization
@testable import WisprLocalCore

/// History playback: entries and clips are linked by a stable id (never a timestamp), the play
/// button follows the disk, deletion cascades both ways, outcome-only entries never have a clip,
/// one clip plays at a time and 🌐 stops it, and re-transcription writes nothing to History.
enum PlaybackFixtures {
    static func tempDir(_ tag: String = "hp") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    static func inserted(_ text: String, at t: TimeInterval = 1_000, id: UUID = UUID()) -> HistoryEntry {
        var e = HistoryEntry(id: id, timestamp: Date(timeIntervalSince1970: t), engine: "fluidaudio:v2", cleaner: "rules",
                             audioDuration: 1, speechDuration: 0.8, outcome: .inserted)
        e.raw = text.lowercased(); e.final = text
        return e
    }

    static let samples = [Float](repeating: 0.1, count: 1_600)

    static func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    /// A history + recordings pair in one temp folder.
    static func library(limit: Int = 20) -> (HistoryLibrary, URL) {
        let root = tempDir()
        let lib = HistoryLibrary(history: HistoryStore(directory: root),
                                 recordings: DebugRecordingStore(directory: root.appendingPathComponent("DebugRecordings"),
                                                                 limit: limit, isEnabled: { true }))
        return (lib, root)
    }

    static func add(_ e: HistoryEntry, to lib: HistoryLibrary, clip: Bool = true) async throws {
        await lib.index.appendEntry(e)
        try await lib.index.flush()
        if clip { _ = lib.recordings.save(samples: samples, entry: e) }
    }
}

@Suite struct HistoryIDLinkingTests {
    typealias F = PlaybackFixtures

    @Test func newEntriesGetDistinctIDsThatRoundTrip() throws {
        let a = HistoryEntry(outcome: .inserted), b = HistoryEntry(outcome: .inserted)
        #expect(a.id != b.id)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(HistoryEntry.self, from: enc.encode(a)).id == a.id)
    }

    /// Removing a rejected model's execution path must preserve existing history entries.
    @MainActor @Test func retiredModelHistoryStillRoundTrips() throws {
        var entry = F.inserted("Legacy dictation.")
        entry.engine = "fluidaudio:phonon2"
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.engine == entry.engine)
        #expect(decoded.final == entry.final)
        #expect(decoded.variant == nil)
        #expect(Retranscription.otherVariant(for: decoded, active: .parakeetV2) == .parakeetUltra)
    }

    /// Lines written before ids existed get an id on read: stable across reads, distinct per
    /// line, and persisted unchanged once the file is rewritten.
    @Test func legacyLinesGetStableIDsOnRead() async throws {
        let dir = F.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = """
        {"audioDuration":1,"cleaner":"rules","engine":"fluidaudio:v2","final":"One.","latencies":{"asrMs":0,"cleanupMs":0,"dictionaryMs":0,"insertMs":0,"totalMs":0,"vadMs":0},"outcome":"inserted","raw":"one","speechDuration":1,"timestamp":"2026-10-01T10:00:00Z"}
        {"audioDuration":1,"cleaner":"rules","engine":"fluidaudio:v2","final":"Two.","latencies":{"asrMs":0,"cleanupMs":0,"dictionaryMs":0,"insertMs":0,"totalMs":0,"vadMs":0},"outcome":"inserted","raw":"two","speechDuration":1,"timestamp":"2026-10-01T10:00:00Z"}

        """
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("history.jsonl"))
        let store = HistoryStore(directory: dir)
        let index = HistoryIndex(store: store)
        await index.load()
        let first = await index.allEntries()
        let reread = HistoryIndex(store: store)
        await reread.load()
        let second = await reread.allEntries()
        #expect(first.count == 2)
        #expect(first.map(\.id) == second.map(\.id), "id must be stable across reads")
        #expect(first[0].id != first[1].id, "same timestamp, different lines → different ids")
        // Raw deletion preserves legacy bytes and their migrated identities across relaunch.
        let extra = F.inserted("Temporary.")
        await index.appendEntry(extra)
        try await index.flush()
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\"id\":\"\(extra.id.uuidString)\""))
        await index.delete(ids: [extra.id])
        try await index.flush()
        let relaunched = HistoryIndex(store: store)
        await relaunched.load()
        #expect(await relaunched.allEntries().map(\.id) == first.map(\.id))
    }

    /// Clips are `<id>.wav` + `<id>.json`; two dictations in the same millisecond stay separate.
    @Test func clipsAreNamedByIDNotTimestamp() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = F.inserted("Alpha.", at: 5_000), b = F.inserted("Beta.", at: 5_000)
        try await F.add(a, to: lib); try await F.add(b, to: lib)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: lib.recordings.directory.path))
        #expect(names == ["\(a.id).wav", "\(a.id).json", "\(b.id).wav", "\(b.id).json"])
        let side = try JSONSerialization.jsonObject(with: Data(contentsOf: lib.recordings.directory
            .appendingPathComponent("\(a.id).json"))) as? [String: Any]
        #expect(side?["id"] as? String == a.id.uuidString)
        #expect(lib.clipURL(for: a)?.lastPathComponent == "\(a.id).wav")
        #expect(lib.recordings.clipIDs() == [a.id, b.id])
        // Permissions (SEC-14) still hold for id-named files.
        #expect(F.mode(lib.recordings.directory) == 0o700)
        #expect(F.mode(lib.recordings.directory.appendingPathComponent("\(a.id).wav")) == 0o600)
        #expect(F.mode(lib.recordings.directory.appendingPathComponent("\(a.id).json")) == 0o600)
    }
}

@Suite struct HistoryPlayButtonTests {
    typealias F = PlaybackFixtures

    @Test func playButtonOnlyWhenTheClipExists() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let withClip = F.inserted("Kept."), without = F.inserted("Not kept.")
        try await F.add(withClip, to: lib); try await F.add(without, to: lib, clip: false)
        let ids = lib.recordings.clipIDs()
        #expect(HistoryPlayback.of(withClip, clipIDs: ids) == .playable)
        #expect(HistoryPlayback.of(withClip, clipIDs: ids).showsPlayButton)
        #expect(HistoryPlayback.of(without, clipIDs: ids) == .noClip)
        #expect(!HistoryPlayback.of(without, clipIDs: ids).showsPlayButton)
        #expect(lib.clipURL(for: without) == nil)
    }

    @Test func disabledWaveformTooltip() {
        #expect(HistoryPlayback.noClipHelp(recordingOn: false)
            == "Turn on ‘Keep last 20 recordings’ in Settings › Privacy to replay dictations")
        #expect(HistoryPlayback.noClipHelp(recordingOn: true).contains("last 20"))
    }
}

@Suite(.serialized) struct HistoryDeletionCascadeTests {
    typealias F = PlaybackFixtures

    @Test func deletingAnEntryDeletesItsClipOnly() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = F.inserted("A."), b = F.inserted("B.", at: 2_000)
        try await F.add(a, to: lib); try await F.add(b, to: lib)
        await lib.index.delete(ids: [a.id])
        try await lib.index.flush()
        #expect((await lib.index.allEntries()).map(\.id) == [b.id])
        #expect(lib.recordings.clipIDs() == [b.id])
        let dir = lib.recordings.directory
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(a.id).json").path))
        #expect(F.mode(dir) == 0o700)
    }

    @Test func clearAllDeletesEveryClip() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        try await F.add(F.inserted("A."), to: lib); try await F.add(F.inserted("B.", at: 2_000), to: lib)
        await lib.index.clear()
        try await lib.index.flush()
        #expect((await lib.index.allEntries()).isEmpty)
        #expect((try FileManager.default.contentsOfDirectory(atPath: lib.recordings.directory.path)).isEmpty)
    }

    /// The other direction: Settings › Privacy › Delete All removes play buttons (and tells
    /// History), but never touches the history entries.
    @Test func deleteAllRecordingsRemovesPlayButtonsAndNotifies() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = F.inserted("A.")
        try await F.add(a, to: lib)
        #expect(HistoryPlayback.of(a, clipIDs: lib.recordings.clipIDs()) == .playable)
        let notified = Mutex(0)
        let token = NotificationCenter.default.addObserver(forName: DebugRecordingStore.didChangeNotification,
                                                           object: lib.recordings, queue: nil) { _ in notified.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }
        lib.recordings.deleteAll()
        #expect(notified.withLock { $0 } >= 1)
        #expect(HistoryPlayback.of(a, clipIDs: lib.recordings.clipIDs()) == .noClip)
        #expect((await lib.index.allEntries()).map(\.id) == [a.id])
    }

    /// Rolling limit: the pruned (oldest) entry loses its play button; History is untouched.
    @Test func rollingPruneStaysConsistent() async throws {
        let (lib, root) = F.library(limit: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let es = (0..<3).map { F.inserted("E\($0).", at: 1_000 + Double($0)) }
        for e in es { try await F.add(e, to: lib) }
        let ids = lib.recordings.clipIDs()
        #expect(ids == [es[1].id, es[2].id])
        #expect(HistoryPlayback.of(es[0], clipIDs: ids) == .noClip)
        #expect((await lib.index.allEntries()).count == 3)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: lib.recordings.directory.path))?.count == 4)
    }

    /// Startup sweep: orphans (deleted entry, unpaired file, pre-id timestamp name) go; linked
    /// clips stay; files newer than the cutoff are never touched; other file types are left.
    @Test func startupSweepRemovesOrphans() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = F.inserted("Kept.")
        try await F.add(kept, to: lib)
        let orphan = F.inserted("Gone.", at: 2_000)
        _ = lib.recordings.save(samples: F.samples, entry: orphan)  // clip without a history line
        let dir = lib.recordings.directory
        let wavData = WAV.encode(F.samples, sampleRate: 16_000)
        try wavData.write(to: dir.appendingPathComponent("20261002-212549.123.wav"))  // legacy name
        try Data("{}".utf8).write(to: dir.appendingPathComponent("20261002-212549.123.json"))
        let unpaired = UUID()
        try wavData.write(to: dir.appendingPathComponent("\(unpaired).wav"))
        try Data("note".utf8).write(to: dir.appendingPathComponent("README.txt"))
        let cutoff = Date().addingTimeInterval(1)
        let removed = await lib.index.sweepOrphans(cutoff: cutoff)
        #expect(removed == 5)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
            == ["\(kept.id).wav", "\(kept.id).json", "README.txt"])
        // A clip saved after the sweep's cutoff is never treated as an orphan.
        let late = F.inserted("Late.", at: 3_000)
        _ = lib.recordings.save(samples: F.samples, entry: late)
        #expect(lib.recordings.sweep(keeping: [kept.id], cutoff: Date().addingTimeInterval(-60)) == 0)
        #expect(lib.recordings.clipIDs() == [kept.id, late.id])
    }

    @Test func sweepAppliesTheRollingLimit() async throws {
        let (lib, root) = F.library(limit: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = lib.recordings.directory
        // Three linked pairs written by a store with a larger limit (e.g. an older build).
        let wide = DebugRecordingStore(directory: dir, limit: 10, isEnabled: { true })
        let es = (0..<3).map { F.inserted("E\($0).", at: 1_000 + Double($0)) }
        for e in es { await lib.index.appendEntry(e); _ = wide.save(samples: F.samples, entry: e) }
        lib.history.flush()
        #expect(await lib.index.sweepOrphans(cutoff: Date().addingTimeInterval(1)) == 2)
        #expect(lib.recordings.clipIDs() == [es[1].id, es[2].id])
    }
}

/// SEC-2: an outcome-only entry has no text; only SAFETY REFUSALS never have a clip (failed and
/// empty dictations keep theirs so the user can hear why — retention table, 2026-10-03).
@MainActor @Suite(.serialized) struct OutcomeOnlyClipTests {
    typealias F = PlaybackFixtures

    @Test func audioPolicyIsEverythingButSafetyRefusals() {
        let all: [HistoryEntry.Outcome] = [.inserted, .noSpeech, .emptyAfterCleanup, .noTextRecognised, .blockedByConflict,
                                           .blockedBySecureInput, .focusChanged, .transcriptionTimedOut,
                                           .insertFailed, .transcriptionFailed, .blockedByRemoteSecureInput]
        for o in all { #expect(o.mayKeepDebugAudio == !o.isSafetyRefusal, "\(o)") }
    }

    @Test func storeRefusesSafetyRefusals() {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        for o in [HistoryEntry.Outcome.blockedBySecureInput, .blockedByRemoteSecureInput, .focusChanged, .blockedByConflict] {
            let e = HistoryEntry(outcome: o)
            #expect(lib.recordings.save(samples: F.samples, entry: e) == nil, "\(o)")
            #expect(HistoryPlayback.of(e, clipIDs: [e.id]) == .outcomeOnly)
            #expect(lib.clipURL(for: e) == nil)
        }
        #expect(lib.recordings.clipIDs().isEmpty)
    }

    @Test func failedAndEmptyDictationsKeepAPlayableClip() {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        for o in [HistoryEntry.Outcome.noSpeech, .emptyAfterCleanup, .noTextRecognised, .transcriptionFailed,
                  .transcriptionTimedOut, .insertFailed] {
            let e = HistoryEntry(outcome: o)
            #expect(lib.recordings.save(samples: F.samples, entry: e) != nil, "\(o)")
            #expect(HistoryPlayback.of(e, clipIDs: lib.recordings.clipIDs()) == .playable, "\(o)")
            #expect(HistoryPlayback.of(e, clipIDs: []) == .outcomeOnly, "\(o) without a clip")
            #expect(e.raw.isEmpty && e.final.isEmpty, "audio only, never text")
        }
    }

    /// Through the real pipeline: cleanup leaves nothing → outcome-only (no text), clip kept.
    @Test func pipelineKeepsClipButNoTextForEmptyDictation() async {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let (e, p) = await makeEnv(text: "um", debugRecordings: lib.recordings)
        _ = await p.process(samples: e.audio.samples, target: e.front)
        let h = e.history.entries.last!
        #expect(!h.outcome.retainsContent)
        #expect(h.raw.isEmpty && h.final.isEmpty)
        await p.flushDebugRecordings()
        #expect(lib.recordings.clipIDs() == [h.id])
    }
}

@MainActor final class FakeClipPlayer: ClipPlaying {
    let url: URL
    var duration: TimeInterval = 4
    var currentTime: TimeInterval = 1
    var onFinish: (@MainActor () -> Void)?
    var playing = false
    var stops = 0
    init(url: URL) { self.url = url }
    func play() -> Bool { playing = true; return true }
    func stop() { playing = false; stops += 1 }
}

@MainActor @Suite struct ClipPlaybackTests {
    let dir = PlaybackFixtures.tempDir("play")

    func make(dictating: @escaping @MainActor () -> Bool = { false }) -> (ClipPlayback, () -> [FakeClipPlayer]) {
        var made: [FakeClipPlayer] = []
        let pb = ClipPlayback(directory: dir, isDictating: dictating, makePlayer: { url in
            let p = FakeClipPlayer(url: url); made.append(p); return p
        })
        return (pb, { made })
    }

    func clip(_ id: UUID) -> URL { dir.appendingPathComponent("\(id).wav") }

    @Test func onlyOneClipPlaysAtATime() {
        let (pb, made) = make()
        let a = UUID(), b = UUID()
        #expect(pb.play(id: a, url: clip(a)))
        #expect(pb.play(id: b, url: clip(b)))
        #expect(pb.playingID == b)
        #expect(made().count == 2)
        #expect(!made()[0].playing && made()[0].stops == 1, "the first clip is stopped before the second starts")
        #expect(made()[1].playing)
        #expect(made().filter(\.playing).count == 1)
        #expect(abs(pb.progress - 0.25) < 0.0001)
    }

    @Test func toggleStopsTheSameClip() {
        let (pb, made) = make()
        let a = UUID()
        pb.toggle(id: a, url: clip(a))
        #expect(pb.isPlaying(a))
        pb.toggle(id: a, url: clip(a))
        #expect(pb.playingID == nil)
        #expect(!made()[0].playing)
    }

    /// 🌐 pressed: playback stops first (the hotkey path calls this before the pipeline).
    @Test func globeStopsPlayback() {
        let (pb, made) = make()
        let a = UUID()
        pb.play(id: a, url: clip(a))
        pb.handleHotkey(.commitRecording)
        #expect(pb.isPlaying(a), "only a dictation START stops playback")
        pb.handleHotkey(.startRecording)
        #expect(pb.playingID == nil)
        #expect(!made()[0].playing)
    }

    @Test func refusesToPlayWhileDictating() {
        let busy = Mutex(true)
        let (pb, made) = make(dictating: { busy.withLock { $0 } })
        let a = UUID()
        #expect(!pb.play(id: a, url: clip(a)))
        #expect(pb.playingID == nil && made().isEmpty)
        busy.withLock { $0 = false }
        #expect(pb.play(id: a, url: clip(a)))
    }

    @Test func localRecordingsOnly() {
        let (pb, made) = make()
        let a = UUID()
        #expect(!pb.play(id: a, url: URL(string: "https://example.com/\(a).wav")!))
        #expect(!pb.play(id: a, url: FileManager.default.temporaryDirectory.appendingPathComponent("\(a).wav")))
        #expect(!pb.play(id: a, url: dir.appendingPathComponent("\(a).json")))
        #expect(!pb.play(id: a, url: dir.appendingPathComponent("../\(a).wav")))
        #expect(made().isEmpty)
    }

    @Test func stopsOnDeletionClipRemovalAndFinish() {
        let (pb, made) = make()
        let a = UUID(), b = UUID()
        pb.play(id: a, url: clip(a))
        pb.stop(ifPlaying: b)
        #expect(pb.isPlaying(a))
        pb.stop(ifPlaying: a)  // row deleted
        #expect(pb.playingID == nil)
        pb.play(id: a, url: clip(a))
        pb.clipsChanged(available: [b])  // Delete All / pruning removed it
        #expect(pb.playingID == nil)
        pb.play(id: a, url: clip(a))
        made().last!.onFinish?()  // played to the end
        #expect(pb.playingID == nil)
        pb.play(id: a, url: clip(a))
        pb.stop()  // window closed
        #expect(pb.playingID == nil && made().allSatisfy { !$0.playing })
    }
}

/// Records which model was made, and whether it was prepared and released.
final class SpyTranscriber: Transcriber, @unchecked Sendable {
    let variant: ASRModelVariant
    let text: String
    let fail: Bool
    let delay: Duration
    let prepared = Mutex(0), unloaded = Mutex(0), calls = Mutex(0)
    init(_ v: ASRModelVariant, text: String, fail: Bool = false, delay: Duration = .zero) {
        variant = v; self.text = text; self.fail = fail; self.delay = delay
    }
    var engineName: String { "fluidaudio:\(variant.rawValue)" }
    func prepare() async throws {
        prepared.withLock { $0 += 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
    }
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String {
        calls.withLock { $0 += 1 }
        if fail { throw CocoaError(.fileReadCorruptFile) }
        return text
    }
    func unload() async { unloaded.withLock { $0 += 1 } }
}

@MainActor @Suite(.serialized) struct RetranscriptionTests {
    typealias F = PlaybackFixtures

    @Test func otherModelMapping() {
        var e = F.inserted("x")
        #expect(Retranscription.otherVariant(for: e, active: .parakeetV2) == .parakeetUltra)
        e.engine = "fluidaudio:ultra"
        #expect(Retranscription.otherVariant(for: e, active: .parakeetV2) == .parakeetV2)
        e.engine = "fake"
        #expect(Retranscription.otherVariant(for: e, active: .parakeetUltra) == .parakeetV2)
    }

    /// Loads the other model lazily, transcribes the clip, shows the text, releases the model,
    /// and writes nothing to History.
    @Test func retranscribesWithTheOtherModelAndWritesNoHistory() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = F.inserted("The cluster is healthy.")
        try await F.add(e, to: lib)
        let before = try Data(contentsOf: lib.history.fileURL)
        var made: [SpyTranscriber] = []
        let r = Retranscription(makeTranscriber: { v in
            let t = SpyTranscriber(v, text: "the cluster is healthy", delay: .milliseconds(50)); made.append(t); return t
        }, isDictating: { false })
        #expect(made.isEmpty, "nothing is loaded until asked")
        let clip = try #require(lib.clipURL(for: e))
        let task = try #require(r.start(entryID: e.id, clip: clip, variant: .parakeetUltra))
        #expect(r.state == .preparing(.parakeetUltra))
        #expect(!r.canStart)
        await task.value
        #expect(r.state == .done(.parakeetUltra, "the cluster is healthy"))
        #expect(r.entryID == e.id)
        #expect(made.map(\.variant) == [.parakeetUltra])
        #expect(made[0].prepared.withLock { $0 } == 1)
        #expect(made[0].unloaded.withLock { $0 } == 1, "the extra model is released")
        lib.history.flush()
        #expect(try Data(contentsOf: lib.history.fileURL) == before, "History is untouched")
        #expect((await lib.index.allEntries()).count == 1)
    }

    @Test func disabledWhileDictating() {
        var made = 0
        let r = Retranscription(makeTranscriber: { v in made += 1; return SpyTranscriber(v, text: "") }, isDictating: { true })
        #expect(!r.canStart)
        #expect(r.start(entryID: UUID(), clip: URL(fileURLWithPath: "/dev/null"), variant: .parakeetUltra) == nil)
        #expect(r.state == .idle && made == 0)
    }

    @Test func failureStillReleasesTheModel() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = F.inserted("x")
        try await F.add(e, to: lib)
        let spy = SpyTranscriber(.parakeetUltra, text: "", fail: true)
        let r = Retranscription(makeTranscriber: { _ in spy }, isDictating: { false })
        await r.start(entryID: e.id, clip: try #require(lib.clipURL(for: e)), variant: .parakeetUltra)?.value
        guard case .failed = r.state else { Issue.record("expected failure, got \(r.state)"); return }
        #expect(spy.unloaded.withLock { $0 } == 1)
    }

    /// A dictation starting mid-run discards it; the model is still released.
    @Test func dictationStartCancelsARun() async throws {
        let (lib, root) = F.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let e = F.inserted("x")
        try await F.add(e, to: lib)
        let spy = SpyTranscriber(.parakeetUltra, text: "late", delay: .milliseconds(100))
        let r = Retranscription(makeTranscriber: { _ in spy }, isDictating: { false })
        let task = r.start(entryID: e.id, clip: try #require(lib.clipURL(for: e)), variant: .parakeetUltra)
        r.handleHotkey(.startRecording)
        #expect(r.state == .idle)
        await task?.value
        #expect(r.state == .idle, "a discarded run never shows its result")
        #expect(spy.unloaded.withLock { $0 } == 1)
    }
}
