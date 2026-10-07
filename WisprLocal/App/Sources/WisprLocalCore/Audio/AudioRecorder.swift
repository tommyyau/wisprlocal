@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Records 16 kHz mono Float32 samples into memory.
@MainActor
public protocol AudioCapturing: AnyObject {
    /// Called on the main actor with a 0...1 level roughly every audio buffer (~20-100 ms).
    var onLevel: ((Float) -> Void)? { get set }
    /// Called on the main actor when the max duration is reached (recording is still running;
    /// the owner should stop/commit it).
    var onMaxDurationReached: (() -> Void)? { get set }
    /// Capture could not restart after a device change; commit the samples collected so far.
    var onCaptureInterrupted: (@MainActor (String) -> Void)? { get set }
    func start() throws
    /// Keep capturing for `tail` (so the last word isn't clipped), then stop the engine (mic
    /// indicator off) and return the captured samples.
    func stop(tail: Duration) async -> [Float]
    /// Adaptive tail (see `CaptureTailPolicy`): stop once the buffer ends in silence (after the
    /// policy minimum) or at the maximum. Default: the fixed maximum tail.
    func stop(adaptiveTail: CaptureTailPolicy) async -> [Float]
    /// Stop immediately and discard.
    func cancel()
    /// Whether Apple voice processing (Settings › Microphone › "Noise reduction") is actually on
    /// for the current capture; nil = unknown (fakes). Recorded per dictation in history.
    var captureVoiceProcessingActive: Bool? { get }

    // Warm mic (`WarmMicController`): keep the engine running between dictations so the next
    // recording doesn't lose its first ~0.2 s to engine start-up.
    /// Start (or keep) the engine running, feeding the in-memory pre-roll ring.
    func enterWarm() throws
    /// Stop warm mode: zero + free the ring, and stop the engine unless a recording is running.
    func leaveWarm()
    /// The engine is running warm (ring active) between or during dictations.
    var isWarm: Bool { get }
    /// Whether the most recent `start()` found the engine already running (pre-roll prepended,
    /// audio flows immediately). False = cold start (the HUD shows "starting" until audio flows).
    var lastStartWasWarm: Bool { get }
    /// When true, `stop` keeps the engine running warm instead of stopping it (the controller
    /// then starts the 60 s window). Set by `WarmMicController`.
    var keepWarmAfterStop: Bool { get set }
}

extension AudioCapturing {
    public var onCaptureInterrupted: (@MainActor (String) -> Void)? {
        get { nil }
        set {}
    }
    public var captureVoiceProcessingActive: Bool? { nil }
    public func enterWarm() throws {}
    public func leaveWarm() {}
    public var isWarm: Bool { false }
    public var lastStartWasWarm: Bool { false }
    public var keepWarmAfterStop: Bool { get { false } set {} }
    public func stop(adaptiveTail: CaptureTailPolicy) async -> [Float] { await stop(tail: adaptiveTail.maximum) }
}

public enum AudioConstants {
    public static let sampleRate: Double = 16_000
    public static let maxDuration: TimeInterval = 600  // 10 min
    public static var maxSamples: Int { Int(sampleRate * maxDuration) }
}

/// Thread-safe sample accumulator shared with the realtime tap. While warm it also feeds the
/// pre-roll ring; ring and recording share ONE lock, so `begin(preRoll:)` hands over without a
/// gap or an overlap.
final class SampleSink: Sendable {
    private struct State {
        var samples: [Float] = []; var active = false; var hitMax = false
        var ring: PreRollRing?
    }
    private let state = Mutex(State())
    let maxSamples: Int
    let ringCapacity: Int
    init(maxSamples: Int, ringCapacity: Int = MicWarmPolicy.samples(MicWarmPolicy.ringDuration)) {
        self.maxSamples = maxSamples; self.ringCapacity = ringCapacity
    }

    /// Start a recording. `preRoll` = how many of the ring's newest samples to prepend (0 when
    /// cold). Returns the number actually prepended. This is the ONLY reader of the ring.
    @discardableResult
    func begin(preRoll: Int = 0) -> Int {
        state.withLock { s in
            let pre = s.ring?.last(preRoll) ?? []
            s.samples = []; s.samples.reserveCapacity(16_000 * 30)
            s.samples.append(contentsOf: pre)
            s.active = true; s.hitMax = false
            return pre.count
        }
    }

    /// Start a recording on an engine that is `engineRunning`: warm (engine running AND ring fed)
    /// prepends exactly `MicWarmPolicy.preRoll`; cold prepends nothing. Returns whether it was warm.
    @discardableResult
    func beginRecording(engineRunning: Bool) -> Bool {
        let warm = engineRunning && ringEnabled
        begin(preRoll: warm ? MicWarmPolicy.samples(MicWarmPolicy.preRoll) : 0)
        return warm
    }

    func enableRing() { state.withLock { if $0.ring == nil { $0.ring = PreRollRing(capacity: ringCapacity) } } }
    /// Zero every ring sample, then free it.
    func disableRing() { state.withLock { $0.ring?.zeroAndFree(); $0.ring = nil } }
    var ringEnabled: Bool { state.withLock { $0.ring != nil } }
    /// Tests only: ring contents (never used by the app).
    func ringSnapshotForTesting() -> [Float] { state.withLock { $0.ring?.last($0.ring?.count ?? 0) ?? [] } }

    /// Returns true exactly once when the cap is first reached.
    func append(_ p: UnsafeBufferPointer<Float>) -> Bool {
        state.withLock { s in
            s.ring?.write(p)
            guard s.active else { return false }
            let room = maxSamples - s.samples.count
            if room > 0 { s.samples.append(contentsOf: p.prefix(room)) }
            if s.samples.count >= maxSamples && !s.hitMax { s.hitMax = true; return true }
            return false
        }
    }
    /// Copy of the last `n` samples (n ≤ count) — for the adaptive-tail energy check.
    func last(_ n: Int) -> [Float] { state.withLock { Array($0.samples.suffix(n)) } }
    func end() -> [Float] { state.withLock { s in s.active = false; let out = s.samples; s.samples = []; return out } }
    var isActive: Bool { state.withLock { $0.active } }
    /// Tap work needed at all (recording, or warm ring).
    var isListening: Bool { state.withLock { $0.active || $0.ring != nil } }
}

/// Converts arbitrary PCM buffers to 16 kHz mono Float32. Separate for unit testing.
public final class MonoResampler: @unchecked Sendable {
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(inputFormat: AVAudioFormat, sampleRate: Double = AudioConstants.sampleRate) {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inputFormat, to: out) else { return nil }
        if inputFormat.channelCount > 1 {
            // Downmix: take channel 0 (voice-processing IO puts the processed mic there).
            conv.channelMap = [0]
        }
        self.inputFormat = inputFormat; self.outputFormat = out; self.converter = conv
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true; inStatus.pointee = .haveData; return buffer
        }
        return (status == .error) ? nil : out
    }

    /// Drop the converter's internal history. The sample-rate converter holds back a few output
    /// frames (~6 at 48 → 16 kHz); without a reset, the next run after an engine stop starts with
    /// those stale frames from the PREVIOUS run (`ConverterTests.resetDropsStaleFramesAcrossRuns`).
    public func reset() { converter.reset() }
}

/// The engine-independent half of the capture path, shared by `AudioRecorder` and the
/// continuity harness (`CaptureContinuityTests`): tap buffer → 16 kHz converter → sink (+ warm
/// ring). The recorder owns the AVAudioEngine; this owns everything the samples pass through.
final class CapturePath: @unchecked Sendable {
    let sink: SampleSink
    let spectrum: SpectrumBands
    let analyzer = SpectrumAnalyzer()
    /// The converter for the current input format (replaced on every engine rebuild).
    private(set) var resampler: MonoResampler?

    init(sink: SampleSink, spectrum: SpectrumBands = SpectrumBands()) { self.sink = sink; self.spectrum = spectrum }

    /// Engine (re)built for `format` (launch, VP toggle, device change): a fresh converter + tap.
    /// The sink — and so any recording in progress — is kept.
    func makeTap(for format: AVAudioFormat, report: @escaping @Sendable (Float, Bool) -> Void) -> AVAudioNodeTapBlock? {
        guard let r = MonoResampler(inputFormat: format) else { return nil }
        resampler = r
        return AudioRecorder.makeTapBlock(sink: sink, resampler: r, analyzer: analyzer, spectrum: spectrum, report: report)
    }

    /// Called immediately before the engine starts from STOPPED: the converter must not carry
    /// frames from the previous run into this one.
    func engineWillStart() { resampler?.reset() }
}

/// AVAudioEngine recorder with optional Apple voice processing (noise suppression / AGC).
///
/// All engine work runs on a private serial queue: device-change rebuilds happen there eagerly
/// while idle (off the key path), and mid-recording they rebuild + restart into the SAME sample
/// sink (a short gap is accepted). `start()` only waits on the queue if a rebuild is in flight.
nonisolated public final class AudioRecorder: AudioCapturing, @unchecked Sendable {
    @MainActor public var onLevel: ((Float) -> Void)?
    @MainActor public var onCaptureInterrupted: (@MainActor (String) -> Void)?
    @MainActor public var onMaxDurationReached: (() -> Void)?

    private let q = DispatchQueue(label: "wisprlocal.audio", qos: .userInteractive)
    // --- state below is only touched on `q` ---
    private var engine = AVAudioEngine()
    private var needsRebuild = true
    private var tapInstalled = false
    private var vpEnabled: Bool
    private var vpActive = false
    private let inputTransport: @Sendable () -> InputTransport
    private var loggedUnknownTransport = false
    /// Engine running (recording and/or warm).
    private var running = false
    private var recording = false
    private var warmStart = false
    private var keepWarm = false
    // ---
    private let path = CapturePath(sink: SampleSink(maxSamples: AudioConstants.maxSamples))
    private var sink: SampleSink { path.sink }
    /// Live 9-band voice spectrum for the HUD (written by the tap, read at display rate).
    public var spectrum: SpectrumBands { path.spectrum }
    private var configObserver: NSObjectProtocol?

    public init(voiceProcessingEnabled: Bool = true,
                inputTransport: @escaping @Sendable () -> InputTransport = InputTransportProbe.defaultInputTransport) {
        vpEnabled = voiceProcessingEnabled
        self.inputTransport = inputTransport
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.q.async { [weak self] in self?.handleConfigurationChange() }
        }
    }

    deinit { if let configObserver { NotificationCenter.default.removeObserver(configObserver) } }

    /// Whether voice processing actually got enabled (false if the device/OS refused).
    public var voiceProcessingActive: Bool { q.sync { vpActive } }
    public var captureVoiceProcessingActive: Bool? { voiceProcessingActive }

    public var isWarm: Bool { q.sync { running && sink.ringEnabled } }
    public var lastStartWasWarm: Bool { q.sync { warmStart } }
    public var keepWarmAfterStop: Bool {
        get { q.sync { keepWarm } }
        set { q.sync { keepWarm = newValue } }
    }

    public func enterWarm() throws {
        try q.sync { [self] in
            guard !vpEnabled else {
                throw AudioError.startFailed("warm mode is off while Noise reduction is on")
            }
            try buildOnQueue(voiceProcessing: false)
            sink.enableRing()
            if !running {
                do { try startEngine() } catch {
                    sink.disableRing(); needsRebuild = true
                    throw AudioError.startFailed(error.localizedDescription)
                }
            }
        }
    }

    public func leaveWarm() {
        q.sync { [self] in
            sink.disableRing()
            if !recording && (vpEnabled || vpActive) {
                try? idleReset()
            } else if running && !recording {
                engine.stop()  // releases the input: the mic indicator turns off
                running = false
            }
        }
        q.async { [self] in if !running { try? idleReset(reprepareExisting: true) } }
    }

    public func setVoiceProcessingEnabled(_ on: Bool) {
        q.async { [self] in
            guard on != vpEnabled else { return }
            vpEnabled = on; needsRebuild = true
            if !running { try? idleReset() }
            else if !recording && on {
                try? idleReset()
            } else if !recording {
                // Warm: rebuild in the new mode and keep warm (the ring restarts empty).
                let wasWarm = sink.ringEnabled
                sink.disableRing()
                do {
                    try buildOnQueue(voiceProcessing: false)
                    if wasWarm { sink.enableRing(); try startEngine() }
                } catch { running = false; Log.error("warm mic rebuild failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Prepare raw audio ahead of time; with VP or Bluetooth, release the idle engine and build cold at `start()`.
    /// Safe to call repeatedly.
    public func prepare() throws { try q.sync { try idleReset() } }

    /// Build/prepare in the background (launch, idle device changes).
    public func prepareInBackground() { q.async { [self] in try? idleReset() } }

    private func handleConfigurationChange() {
        needsRebuild = true
        if running {
            if !recording && IdleInputPolicy.keepInputClosedWhileIdle(vpEnabled: vpEnabled, transport: currentInputTransport()) {
                // The new idle input must stay closed: end the warm window.
                try? idleReset()
                return
            }
            // Device changed mid-utterance: rebuild and keep appending to the same sink.
            // (Also while warm between dictations, which only happens with Noise reduction off.)
            if recording { Log.info("audio device changed mid-recording; engine restarted") }
            do { try buildOnQueue(voiceProcessing: recording && vpEnabled); try startEngine() }
            catch {
                if IdleInputPolicy.keepInputClosedWhileIdle(vpEnabled: vpEnabled, transport: currentInputTransport()) || vpActive { try? idleReset() }
                Log.error("audio restart after device change failed: \(error.localizedDescription)")
                if recording {
                    Task { @MainActor [weak self] in
                        self?.onCaptureInterrupted?(PipelineNotice.captureInterrupted)
                    }
                }
            }
        } else {
            try? idleReset()
        }
    }

    /// Query at each decision on the audio queue; never cache the default input's transport.
    private func currentInputTransport() -> InputTransport {
        dispatchPrecondition(condition: .onQueue(q))
        let transport = inputTransport()
        if transport == .unknown && !loggedUnknownTransport {
            Log.info("input transport: unknown")
            loggedUnknownTransport = true
        }
        return transport
    }

    /// Queue-confined idle preparation: Bluetooth and VPIO engines are fully released.
    /// Switching AirPods to built-in while released fires no configuration change, so the next
    /// built-in start is cold once.
    private func idleReset(reprepareExisting: Bool = false) throws {
        if IdleInputPolicy.keepInputClosedWhileIdle(vpEnabled: vpEnabled, transport: currentInputTransport()) || vpActive {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            engine = AVAudioEngine()  // Do not touch this fresh engine's inputNode while idle.
            vpActive = false
            needsRebuild = true
            running = false
            sink.disableRing()
        } else if reprepareExisting {
            engine.prepare()
        } else {
            try buildOnQueue(voiceProcessing: false)
        }
    }

    /// Always build a usable input graph; idle callers must decide policy in idleReset first.
    private func buildOnQueue(voiceProcessing: Bool) throws {
        guard needsRebuild else { return }
        engine.stop()
        running = false
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine = AVAudioEngine()
        let input = engine.inputNode
        vpActive = false
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Minimise ducking during capture; releasing VPIO at stop lifts it fully.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                vpActive = true
            } catch {
                vpActive = false  // unsupported device/config: raw input rather than failing
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioError.noInputDevice }
        let report: @Sendable (Float, Bool) -> Void = { [weak self] level, hitMax in
            Task { @MainActor in
                self?.onLevel?(level)
                if hitMax { self?.onMaxDurationReached?() }
            }
        }
        guard let tap = path.makeTap(for: format, report: report) else { throw AudioError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
        tapInstalled = true
        engine.prepare()
        needsRebuild = false
    }

    /// The tap runs on the realtime audio thread; built nonisolated so no actor checks fire there.
    static func makeTapBlock(sink: SampleSink, resampler: MonoResampler,
                                     analyzer: SpectrumAnalyzer, spectrum: SpectrumBands,
                                     report: @escaping @Sendable (Float, Bool) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard sink.isListening, let out = resampler.convert(buffer), let data = out.floatChannelData else { return }
            let p = UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))
            let hitMax = sink.append(p)
            guard sink.isActive else { return }  // warm only: ring fed, no level/spectrum
            var sum: Float = 0
            for x in p { sum += x * x }
            let rms = p.isEmpty ? 0 : (sum / Float(p.count)).squareRoot()
            // 512-point FFT bands with display tracking in <=320-sample sub-blocks, allocation-free.
            spectrum.write(analyzer.process(p))
            report(min(1, rms * 8), hitMax)
        }
    }

    public func start() throws {
        try q.sync { [self] in
            // A pending rebuild stops a warm engine: that start is cold.
            do { try buildOnQueue(voiceProcessing: vpEnabled) } catch {
                if IdleInputPolicy.keepInputClosedWhileIdle(vpEnabled: vpEnabled, transport: currentInputTransport()) || vpActive { try? idleReset() }
                throw error
            }
            path.analyzer.resetDisplayGain()
            warmStart = sink.beginRecording(engineRunning: running)
            if !running {
                do { try startEngine() } catch {
                    _ = sink.end()
                    needsRebuild = true
                    if IdleInputPolicy.keepInputClosedWhileIdle(vpEnabled: vpEnabled, transport: currentInputTransport()) || vpActive { try? idleReset() }
                    throw AudioError.startFailed(error.localizedDescription)
                }
            }
            recording = true
        }
    }

    /// The ONLY place the engine starts (`CaptureContinuityTests.engineStartsOnlyThroughStartEngine`):
    /// the converter is reset first so a run never begins with the previous run's frames.
    private func startEngine() throws {
        guard tapInstalled else { throw AudioError.startFailed("input graph is not prepared") }
        path.engineWillStart()
        try engine.start()
        running = true
    }

    /// Exercise the prepared-engine guard without building or opening an audio input.
    func startPreparedEngineForTesting() throws { try q.sync { try startEngine() } }

    public func stop(tail: Duration) async -> [Float] {
        if tail > .zero { try? await Task.sleep(for: tail) }
        return stopNow()
    }

    public func stop(adaptiveTail p: CaptureTailPolicy) async -> [Float] {
        let clock = ContinuousClock(), t0 = clock.now
        let rate = AudioConstants.sampleRate
        // Threshold from this recording (last ≤ 30 s), computed once at key-up.
        let threshold = p.threshold(for: sink.last(Int(rate * 30))[...], sampleRate: rate)
        let window = CaptureTailPolicy.samples(p.silence, rate: rate)
        if p.minimum > .zero { try? await Task.sleep(for: p.minimum) }
        while true {
            let elapsed = clock.now - t0
            let silent = window > 0 && p.endsInSilence(sink.last(window)[...], threshold: threshold, sampleRate: rate)
            if p.shouldStop(elapsed: elapsed, endsInSilence: silent) { break }
            try? await Task.sleep(for: min(.milliseconds(10), p.maximum - elapsed))
        }
        return stopNow()
    }

    public func cancel() { _ = stopNow() }

    private func stopNow() -> [Float] {
        let samples = q.sync { [self] () -> [Float] in
            recording = false
            spectrum.clear()
            let out = sink.end()
            if vpEnabled || vpActive {
                try? idleReset()  // Release VPIO synchronously so ducking lifts at stop.
            } else if keepWarm && running {
                sink.enableRing()  // stay warm; WarmMicController owns the 60 s window
            } else {
                // stop() (not pause) releases the input so the mic indicator turns off.
                engine.stop()
                running = false
                sink.disableRing()
            }
            return out
        }
        // Re-prepare off the key path so the next start stays fast.
        q.async { [self] in if !running { try? idleReset(reprepareExisting: true) } }
        return samples
    }
}

public enum AudioError: Error, LocalizedError {
    case noInputDevice
    case startFailed(String)
    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input available"
        case .startFailed(let m): return "Could not start microphone: \(m)"
        }
    }
}
