import Foundation
import AVFoundation
import Synchronization
import CoreAudio
import Testing
@testable import WisprLocalCore

@Suite struct IdleInputPolicyTests {
    @Test(arguments: [false, true], [InputTransport.builtIn, .bluetooth, .other, .unknown])
    func idleInputTruthTable(vpEnabled: Bool, transport: InputTransport) {
        #expect(IdleInputPolicy.keepInputClosedWhileIdle(vpEnabled: vpEnabled, transport: transport)
                == (vpEnabled || transport == .bluetooth))
    }

    // The injected Bluetooth policy releases without touching inputNode. The hook drains the
    // serial queue and hits the tap guard before AVAudioEngine.start(), so no mic permission is needed.
    @Test(arguments: [false, true])
    func releasedEngineStartThrowsWithoutOpeningInput(background: Bool) throws {
        let recorder = AudioRecorder(voiceProcessingEnabled: false, inputTransport: { .bluetooth })
        if background { recorder.prepareInBackground() } else { try recorder.prepare() }
        do {
            try recorder.startPreparedEngineForTesting()
            Issue.record("An empty engine must refuse to start")
        } catch AudioError.startFailed(let message) {
            #expect(message == "input graph is not prepared")
        } catch {
            Issue.record("Expected AudioError.startFailed, got \(error)")
        }
        #expect(!recorder.isWarm && !recorder.voiceProcessingActive)
    }

    @Test(arguments: [false, true], [false, true])
    func bluetoothStopFollowsReadinessUnlessVP(vp: Bool, keepReady: Bool) async {
        let recorder = AudioRecorder(voiceProcessingEnabled: vp, inputTransport: { .bluetooth })
        recorder.keepWarmAfterStop = keepReady
        recorder.seedCaptureForTesting(samples: [0.2], vpActive: vp)
        #expect(await recorder.stop(tail: .zero) == [0.2])
        #expect(recorder.isWarm == (keepReady && !vp))
        #expect(recorder.voiceProcessingActive == false)
        if keepReady && !vp {
            recorder.feedWarmForTesting([0.3])
            #expect(recorder.hasWarmAudio)
        }
        recorder.leaveWarm(); recorder.drainQueueForTesting()
        #expect(!recorder.isWarm && recorder.warmSamplesForTesting().isEmpty)
        #expect(IdleInputPolicy.canKeepWarm(vpEnabled: vp, transport: .bluetooth) == !vp)
    }

    @Test func bluetoothDeviceNotificationDropsVPWarmEngineAndZeroesRing() async {
        let center = NotificationCenter()
        let transport = Synchronization.Mutex<InputTransport>(.builtIn)
        let recorder = AudioRecorder(voiceProcessingEnabled: true,
                                     inputTransport: { transport.withLock { $0 } }, notificationCenter: center)
        recorder.keepWarmAfterStop = true
        recorder.seedCaptureForTesting(samples: [0.2], vpActive: true)
        _ = await recorder.stop(tail: .zero)
        recorder.feedWarmForTesting([0.31337])
        #expect(recorder.isWarm && recorder.voiceProcessingActive && recorder.hasWarmAudio)
        transport.withLock { $0 = .bluetooth }
        center.post(name: .AVAudioEngineConfigurationChange, object: nil)
        recorder.drainQueueForTesting()
        #expect(!recorder.isWarm && !recorder.voiceProcessingActive)
        #expect(recorder.warmSamplesForTesting().isEmpty)
    }

    @Test func coreAudioTransportsMapWithoutOpeningInput() {
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeUSB) == .other)
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeUnknown) == .unknown)
        #expect(InputTransportProbe.classify(0) == .unknown)
    }
}
