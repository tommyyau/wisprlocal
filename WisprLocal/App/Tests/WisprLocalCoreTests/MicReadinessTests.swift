import Foundation
import Testing
@testable import WisprLocalCore

@Suite struct MicReadinessTests {
    @Test func readsAllFourFlagCombinations() {
        #expect(MicReadiness(keep: false, always: false) == .off)
        #expect(MicReadiness(keep: true, always: false) == .afterDictating)
        #expect(MicReadiness(keep: false, always: true) == .always)
        #expect(MicReadiness(keep: true, always: true) == .always)
    }
    @MainActor @Test func eachChoiceWritesBothFlagsFromEveryCombination() throws {
        let suite = "wisprlocal-test-readiness-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for keep in [true, false] {
            for always in [true, false] {
                for choice in MicReadiness.allCases {
                    settings.keepMicReady = keep
                    settings.alwaysMicReady = always
                    choice.apply(to: settings)
                    #expect(settings.keepMicReady == choice.keep)
                    #expect(settings.alwaysMicReady == choice.always)
                    #expect(MicReadiness(keep: settings.keepMicReady, always: settings.alwaysMicReady) == choice)
                }
            }
        }
    }
}
