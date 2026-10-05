import Foundation
import Testing
@testable import WisprLocalCore

/// "Noise reduction" (voice processing) is OFF by default since 2026-10-03 (it gated
/// real speech in 15 of 20 plane dictations); an explicit stored value always wins.
@MainActor struct VoiceProcessingDefaultTests {
    @Test func neverSetMeansOff() {
        let d = RecordingsDefaultTests.freshDefaults()
        #expect(AppSettings.voiceProcessingDefault == false)
        #expect(!AppSettings(defaults: d).voiceProcessingEnabled)
        #expect(d.object(forKey: AppSettings.Keys.voiceProcessing) == nil, "reading the default doesn't write it")
    }

    @Test func explicitOnIsRespected() {
        let d = RecordingsDefaultTests.freshDefaults()
        d.set(true, forKey: AppSettings.Keys.voiceProcessing)
        #expect(AppSettings(defaults: d).voiceProcessingEnabled)
    }

    @Test func explicitOffStaysOffAndToggleRoundTrips() {
        let d = RecordingsDefaultTests.freshDefaults()
        let s = AppSettings(defaults: d)
        s.voiceProcessingEnabled = true
        #expect(AppSettings(defaults: d).voiceProcessingEnabled)
        s.voiceProcessingEnabled = false
        #expect(d.object(forKey: AppSettings.Keys.voiceProcessing) as? Bool == false)
        #expect(!AppSettings(defaults: d).voiceProcessingEnabled)
    }

    @Test func caveatAppearsInTheHelp() {
        #expect(InfoTopic.noiseReduction.sentences.joined(separator: " ").contains("cut out quiet speech in very loud places"))
        #expect(FAQ.items.first { $0.id == "model" }!.answer.joined().contains("off by default"))
    }
}
