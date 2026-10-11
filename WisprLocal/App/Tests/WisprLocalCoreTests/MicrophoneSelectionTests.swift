import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import WisprLocalCore

@MainActor @Suite struct MicrophoneSelectionTests {
    @Test func explicitChoiceSurvivesRelaunchAndCanReturnToSystemDefault() {
        let defaults = RecordingsDefaultTests.freshDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.preferredInputUID == nil)
        settings.preferredInputUID = "synthetic-microphone"
        #expect(AppSettings(defaults: defaults).preferredInputUID == "synthetic-microphone")
        settings.preferredInputUID = nil
        #expect(AppSettings(defaults: defaults).preferredInputUID == nil)
    }

    @Test func disconnectedSelectionRefusesCaptureWithoutOpeningDefaultMicrophone() throws {
        let uid = "unavailable-microphone-\(UUID())"
        #expect(InputTransportProbe.selectedInputID(uid: uid) == nil)
        let recorder = AudioRecorder(voiceProcessingEnabled: false, preferredInputUID: uid,
                                     notificationCenter: NotificationCenter())
        do {
            try recorder.start()
            Issue.record("A missing explicit microphone must not record from the system default")
        } catch AudioError.selectedInputUnavailable {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(recorder.inputDeviceIDForTesting() == nil)
        #expect(!recorder.isWarm)
    }

    @Test func selectionChangeClearsPreviousMicrophonesWarmAudio() async {
        let recorder = AudioRecorder(voiceProcessingEnabled: false, inputTransport: { .bluetooth },
                                     notificationCenter: NotificationCenter())
        recorder.keepWarmAfterStop = true
        recorder.seedCaptureForTesting(samples: [0.2], vpActive: false)
        _ = await recorder.stop(tail: .zero)
        recorder.feedWarmForTesting([0.3])
        #expect(recorder.hasWarmAudio)
        recorder.setPreferredInputUID("unavailable-microphone-\(UUID())")
        recorder.drainQueueForTesting()
        #expect(recorder.warmSamplesForTesting().isEmpty)
        #expect(!recorder.isWarm)
    }
}

/// Opt-in: opens this Mac's built-in mic, keeps samples only in memory, and never changes the
/// system input. Run with AirPods selected in macOS to exercise the reported routing failure.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct MicrophoneSelectionHardwareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISPRLOCAL_MIC_ROUTING_TEST"] == "1"),
          arguments: [false, true])
    func pinnedBuiltInCapturesAcrossStopsAndRebuilds(voiceProcessing: Bool) async throws {
        #expect(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let uid = "BuiltInMicrophoneDevice"
        let builtIn = try #require(InputTransportProbe.selectedInputID(uid: uid))
        #expect(InputTransportProbe.classify(InputTransportProbe.transport(builtIn)) == .builtIn)
        #expect(InputTransportProbe.uid(builtIn) == uid)
        let systemInput = InputTransportProbe.defaultInputID()
        let recorder = AudioRecorder(voiceProcessingEnabled: voiceProcessing, preferredInputUID: uid)
        defer { recorder.cancel(); recorder.leaveWarm() }
        for _ in 0..<2 {
            try recorder.start()
            try await Task.sleep(for: .seconds(2))
            #expect(recorder.inputDeviceIDForTesting() == builtIn)
            #expect(recorder.voiceProcessingActive == voiceProcessing)
            let samples = await recorder.stop(tail: .zero)
            #expect(samples.count >= 16_000, "Must deliver at least a second of audio")
            #expect(samples.contains { $0.isFinite && $0 != 0 }, "Must receive nonzero hardware samples")
            #expect(InputTransportProbe.defaultInputID() == systemInput, "App selection must not change macOS's input")
            recorder.leaveWarm()
            recorder.drainQueueForTesting()
            recorder.drainQueueForTesting()
        }
    }
}
