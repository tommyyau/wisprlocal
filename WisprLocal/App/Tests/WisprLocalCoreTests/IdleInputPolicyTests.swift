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

    @Test func coreAudioTransportsMapWithoutOpeningInput() {
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeUSB) == .other)
        #expect(InputTransportProbe.classify(kAudioDeviceTransportTypeUnknown) == .unknown)
        #expect(InputTransportProbe.classify(0) == .unknown)
    }
}
