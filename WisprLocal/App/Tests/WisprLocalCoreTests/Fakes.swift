import Foundation
import Synchronization
@testable import WisprLocalCore

@MainActor final class FakeInserter: TextInserter {
    let name: String
    var inserted: [String] = []
    /// When set, `insert` throws it instead of inserting.
    var failWith: Error?
    init(name: String = "fake") { self.name = name }
    func insert(_ text: String) async throws {
        if let failWith { throw failWith }
        inserted.append(text)
    }
}

@MainActor final class FakeAudio: AudioCapturing {
    var onLevel: ((Float) -> Void)?
    var onCaptureInterrupted: (@MainActor (String) -> Void)?
    func interrupt() { onCaptureInterrupted?("Synthetic device failure") }
    var onMaxDurationReached: (() -> Void)?
    var samples: [Float] = []
    var started = 0, stopped = 0, cancelled = 0
    var lastTail: Duration?
    /// Simulates a start on an already-running (warm) engine.
    var warmStart = false
    var lastStartWasWarm: Bool { warmStart }
    func start() throws { started += 1 }
    func stop(tail: Duration) async -> [Float] { stopped += 1; lastTail = tail; return samples }
    func cancel() { cancelled += 1 }
}

struct FakeTrimmer: SpeechTrimmer {
    var hasSpeech = true
    func prepare() async throws {}
    func trim(_ samples: [Float]) async throws -> [Float]? { hasSpeech ? samples : nil }
}

final class FakeTranscriber: Transcriber, Sendable {
    let text: String
    /// Calls with index < hangCalls block until `release()`, IGNORING cancellation (non-cooperative).
    let hangCalls: Int
    let gate = HangGate()
    let calls = Mutex(0)
    let resets = Mutex(0)
    init(text: String, hangCalls: Int = 0) {
        self.text = text; self.hangCalls = hangCalls
    }
    /// Lets every hung call finish.
    func release() { gate.release() }
    var engineName: String { "fake" }
    var callCount: Int { calls.withLock { $0 } }
    func prepare() async throws {}
    func reset() async { resets.withLock { $0 += 1 } }
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String {
        let n = calls.withLock { v in v += 1; return v - 1 }
        if n < hangCalls {
            await gate.wait()
        }
        return text
    }
}

final class FakeSecureInput: SecureInputChecking, @unchecked Sendable {
    var active = false
    var isSecureInputActive: Bool { active }
}

@MainActor final class FakeClipboard: ClipboardWriting {
    var strings: [String] = []
    func setString(_ s: String) { strings.append(s) }
}

final class MemoryHistory: HistoryWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [HistoryEntry] = []
    var entries: [HistoryEntry] { lock.withLock { _entries } }
    func append(_ entry: HistoryEntry) { lock.withLock { _entries.append(entry) } }
}

func tempDictionary() -> DictionaryStore {
    DictionaryStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("dictionary.json"))
}

/// Caret context fake: defaults to an empty field (text inserted verbatim).
@MainActor final class FakeCaretReader: CaretContextReading {
    var context = CaretContext(preceding: "", elementID: 1)
    var reads: [Int32] = []
    func read(pid: Int32, bundleID: String?) -> CaretContext { reads.append(pid); return context }
}

/// Focus fake: one field in one window whose text before the caret is `preceding()` (wired to
/// "everything inserted so far" by `makeEnv`). `element = nil` = AX unreadable.
@MainActor final class FakeFocusProbe: FocusProbing {
    var element: NSString? = "field-1"
    var window: NSString? = "window-1"
    var preceding: @MainActor () -> String? = { "" }
    var reads = 0
    func snapshot(pid: Int32, precedingChars: Int) async -> FocusSnapshot? {
        reads += 1
        guard let element else { return nil }
        return FocusSnapshot(element: AXIdentity(element), window: window.map { AXIdentity($0) },
                             preceding: precedingChars > 0 ? preceding().map { String($0.suffix(precedingChars)) } : nil)
    }
}

/// Inserter that waits for `release()` before (or after) "pasting", honouring task
/// cancellation like `PasteInserter`: cancelled before the paste → throws, nothing typed.
@MainActor final class GatedInserter: TextInserter {
    let name = "gated"
    var inserted: [String] = []
    var waiting = false
    private var gate: CheckedContinuation<Void, Never>?
    let pasteFirst: Bool
    init(pasteFirst: Bool) { self.pasteFirst = pasteFirst }
    func insert(_ text: String) async throws {
        if pasteFirst { inserted.append(text) }
        waiting = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate = $0 }
        } onCancel: { Task { @MainActor in self.release() } }
        waiting = false
        if !pasteFirst {
            if Task.isCancelled { throw CancellationError() }
            inserted.append(text)
        }
    }
    func release() { gate?.resume(); gate = nil }
}

/// Waits for `cond` to become true by polling. The bound only turns a hang into a failure; it
/// is never what a passing test waits for, so a slow machine cannot make a correct run fail.
@MainActor @discardableResult
func eventually(timeout: Duration = .seconds(30), _ cond: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !cond() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// A non-cooperative hang controlled by the test, not by the wall clock: `wait()` ignores task
/// cancellation and returns only after `release()`.
final class HangGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(c); return false
            }
            if resumeNow { c.resume() }
        }
    }
    func release() {
        let ws = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true; let w = s.waiters; s.waiters = []; return w
        }
        ws.forEach { $0.resume() }
    }
}
