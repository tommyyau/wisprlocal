import AVFoundation
import Foundation
import Testing
import WisprLocalAudioSafety
@testable import WisprLocalCore

@Suite struct AudioGraphSafetyTests {
    /// This is the real framework exception that previously aborted the application. No
    /// input/output node is opened, so this test neither records nor requests permission.
    @Test func emptyGraphPrepareBecomesRecoverableError() {
        var error: NSError?
        #expect(!WLPrepareAudioEngine(AVAudioEngine(), &error))
        #expect(error?.domain == "WisprLocal.AudioGraph")
    }

    @Test func tapOnDetachedNodeBecomesRecoverableError() {
        let engine = AVAudioEngine()
        let detached = AVAudioMixerNode()
        var error: NSError?
        #expect(!WLInstallTapAndPrepare(engine, detached, { _, _ in }, &error))
        #expect(error?.domain == "WisprLocal.AudioGraph")
    }

    @Test func validGraphStillPreparesWithoutOpeningHardware() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        var error: NSError?
        #expect(WLInstallTapAndPrepare(engine, engine.mainMixerNode, { _, _ in }, &error))
        #expect(error == nil)
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    @Test func deviceChangeDropsBuffersUntilConverterMatches() throws {
        let sink = SampleSink(maxSamples: 16_000)
        let path = CapturePath(sink: sink)
        let original = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let changed = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let candidate = path.makeTap(for: original, report: { _, _ in })
        let tap = try #require(candidate)
        sink.begin()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 1024))
        buffer.frameLength = 1024
        for i in 0..<1024 { buffer.floatChannelData![0][i] = 0.3 }
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: 44_100))
        #expect(sink.end().isEmpty, "New-rate audio must not be interpreted using the previous microphone format")
    }

    @Test func idleConfigurationChangeDefersOpeningHardware() throws {
        let center = NotificationCenter()
        let recorder = AudioRecorder(voiceProcessingEnabled: false, inputTransport: { .builtIn }, notificationCenter: center)
        center.post(name: .AVAudioEngineConfigurationChange, object: nil)
        recorder.drainQueueForTesting()
        #expect(recorder.inputDeviceIDForTesting() == nil)
        #expect(throws: AudioError.self) { try recorder.startPreparedEngineForTesting() }
    }
}
