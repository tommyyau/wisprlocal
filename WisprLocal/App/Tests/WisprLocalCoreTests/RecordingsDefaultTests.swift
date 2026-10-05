import Foundation
import Testing
@testable import WisprLocalCore

/// "Keep last 20 recordings (on this Mac)" is ON by default, including for existing installs that
/// never touched it; an explicit OFF is always respected.
@MainActor struct RecordingsDefaultTests {
    static func freshDefaults(_ suite: String = "wisprlocal-tests-recordings-\(UUID().uuidString)") -> UserDefaults {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func neverSetMeansOn() {
        let d = Self.freshDefaults()
        #expect(d.object(forKey: DebugRecordingStore.defaultsKey) == nil)
        #expect(DebugRecordingStore.isEnabled(in: d))
        #expect(AppSettings(defaults: d).keepDebugRecordings)
        // Reading the default doesn't write it: "never set" stays distinguishable.
        #expect(d.object(forKey: DebugRecordingStore.defaultsKey) == nil)
    }

    @Test func existingInstallWithOtherSettingsMigratesToOn() {
        let suite = "wisprlocal-tests-recordings-\(UUID().uuidString)"
        let d = Self.freshDefaults(suite)
        d.set(true, forKey: "onboardingCompleted")       // an existing install…
        d.set(false, forKey: "aiFormattingEnabled")      // …that never touched the recordings toggle
        #expect(AppSettings(defaults: d).keepDebugRecordings)
        let store = DebugRecordingStore(directory: FileManager.default.temporaryDirectory, isEnabled: { DebugRecordingStore.isEnabled(in: UserDefaults(suiteName: suite)!) })
        #expect(store.isEnabled())
    }

    @Test func explicitOffIsRespected() {
        let d = Self.freshDefaults()
        let s = AppSettings(defaults: d)
        s.keepDebugRecordings = false
        #expect(d.object(forKey: DebugRecordingStore.defaultsKey) as? Bool == false)
        #expect(!DebugRecordingStore.isEnabled(in: d))
        #expect(!AppSettings(defaults: d).keepDebugRecordings)
        s.keepDebugRecordings = true
        #expect(AppSettings(defaults: d).keepDebugRecordings)
    }

    @Test func bannerShownOnlyWhenOff() {
        #expect(HistoryPlayback.showsRecordingsOffBanner(recordingOn: false))
        #expect(!HistoryPlayback.showsRecordingsOffBanner(recordingOn: true))
        #expect(HistoryPlayback.recordingsOffBannerText == "Recordings are off — turn on to replay dictations")
    }

    @Test func labelSaysLastTwentyOnThisMac() {
        #expect(AppSettings.keepRecordingsLabel == "Keep last 20 recordings (on this Mac)")
        let help = InfoTopic.debugRecordings.sentences.joined(separator: " ")
        #expect(help.contains("On by default") && help.contains("last 20") && help.contains("Heard vs Inserted")
                && help.contains("stay on this Mac") && help.contains("Delete them anytime"))
    }
}
