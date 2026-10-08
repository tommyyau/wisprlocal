@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import WisprLocalCore

/// No GUI, synthetic key events, saved audio, device selection, or permission prompts.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct StartHardwareBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISPRLOCAL_START_BENCH"] == "1"))
    func builtInColdAndWarm() async throws {
        let transport = InputTransportProbe.defaultInputTransport()
        print("START_BENCH default input transport: \(transport)")
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("START_BENCH SKIP: microphone access is not authorized; no permission prompt issued")
            return
        }
        guard transport == .builtIn else {
            print("START_BENCH SKIP: default input is not built-in; no device selection changed")
            return
        }
        print("VP | state | trial | engineStartMs | keyDownToCaptureMs | keyDownToHUDMs")
        for vp in [false, true] {
            for warm in [false, true] {
                for trial in 1...3 {
                    let rec: StartBenchmarkCapturing = ProductionStartBenchRecorder(vp: vp)
                    if warm {
                        do { try await rec.prime() } catch {
                            await rec.close()
                            print("START_BENCH SKIP: warm input could not start")
                            return
                        }
                        try await Task.sleep(for: .seconds(1)) // settle VPIO before the warm trial
                    }
                    let (e, p) = await makeEnv(audio: rec)
                    let clock = SystemPipelineClock(); p.pipelineClock = clock
                    let down = clock.now
                    p.handle(.startRecording)
                    let deadline = down + .seconds(10)
                    while clock.now < deadline && rec.captureMs == nil && p.status.isRecording {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let captured = rec.captureMs
                    _ = p.cancelDictation() // discard audio; only outcome and timings in memory
                    await rec.close()
                    let hud = e.history.entries.last?.latencies.keyDownToHUDMs
                    func cell(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "unavailable" }
                    print("\(vp ? "on" : "off") | \(warm ? "warm via readiness window" : "cold") | \(trial) | \(cell(rec.engineMs)) | \(cell(captured)) | \(cell(hud))")
                    if captured == nil {
                        print("START_BENCH unavailable capture: input failed or no non-zero audio within 10 s; continuing other trials")
                    }
                }
            }
        }
    }
}

@MainActor private protocol StartBenchmarkCapturing: AudioCapturing {
    var captureMs: Double? { get }
    var engineMs: Double? { get }
    func prime() async throws
    func close() async
}

/// Production recorder for cold and readiness-window warm trials, including VP.
@MainActor private final class ProductionStartBenchRecorder: StartBenchmarkCapturing {
    private let recorder: AudioRecorder
    private let clock = SystemPipelineClock()
    private let measurements = ProductionBenchReadings()
    private(set) var engineMs: Double?
    var captureMs: Double? { measurements.state.withLock { $0.capture } }
    init(vp: Bool) { recorder = AudioRecorder(voiceProcessingEnabled: vp) }
    var onLevel: ((Float) -> Void)? {
        get { recorder.onLevel }
        set { recorder.onLevel = newValue }
    }
    var onMaxDurationReached: (() -> Void)? {
        get { recorder.onMaxDurationReached }
        set { recorder.onMaxDurationReached = newValue }
    }
    var onNonZeroCapture: (@Sendable () -> Void)? {
        get { recorder.onNonZeroCapture }
        set {
            let measurements = self.measurements, clock = self.clock
            recorder.onNonZeroCapture = {
                measurements.state.withLock { r in
                    if let down = r.down, r.capture == nil { r.capture = durationMs(clock.now - down) }
                }
                newValue?()
            }
        }
    }
    var captureVoiceProcessingActive: Bool? { recorder.captureVoiceProcessingActive }
    var isWarm: Bool { recorder.isWarm }
    var lastStartWasWarm: Bool { recorder.lastStartWasWarm }
    func start() throws { throw AudioError.startFailed("benchmark requires asynchronous start") }
    func start(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        let down = clock.now
        measurements.state.withLock { $0.down = down }
        recorder.start { [weak self] result in
            if let self { self.engineMs = durationMs(self.clock.now - down) }
            completion(result)
        }
    }
    func prime() async throws {
        let recorder = recorder
        // Prime using the real post-dictation stop intent and controller-owned readiness window.
        recorder.keepWarmAfterStop = true
        try await Task.detached { try recorder.start() }.value
        _ = await recorder.stop(tail: .zero)
        let controller = WarmMicController(audio: recorder, keepReady: { true }, alwaysReady: { false })
        controller.dictationFinished()
        guard controller.isWarm && recorder.isWarm else { throw AudioError.startFailed("readiness window did not arm") }
    }
    func close() async { recorder.keepWarmAfterStop = false; recorder.leaveWarm(); _ = await recorder.stop(tail: .zero) }
    func stop(tail: Duration) async -> [Float] { await recorder.stop(tail: tail) }
    func cancel() { recorder.cancel() }
}

nonisolated private final class ProductionBenchReadings: Sendable {
    struct State { var down: Duration?; var capture: Double? }
    let state = Mutex(State())
}
