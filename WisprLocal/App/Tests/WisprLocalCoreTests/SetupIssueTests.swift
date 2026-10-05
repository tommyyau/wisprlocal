import Testing
@testable import WisprLocalCore

@Suite struct SetupIssueTests {
    private let granted: [Permission: Bool] = [.microphone: true, .accessibility: true, .inputMonitoring: true]

    @Test func readyHasNoBanner() {
        #expect(SetupIssue.resolve(permissions: granted, health: .ready, globeAction: .doNothing,
                                   consumeGlobe: false, wisprFlow: false, model: .ready).isEmpty)
    }
    @Test(arguments: Permission.allCases) func missingPermission(_ p: Permission) {
        var permissions = granted
        permissions[p] = false
        let issues = SetupIssue.resolve(permissions: permissions, health: .missing([p]), globeAction: .doNothing,
                                        consumeGlobe: true, wisprFlow: false, model: .ready)
        #expect(issues == [.permission(p)])
        #expect(issues.allSatisfy { $0.hasAction })
    }
    @Test(arguments: [PermissionHealth.needsRelaunch, .stalePermission]) func unhealthyGrant(_ health: PermissionHealth) {
        let issues = SetupIssue.resolve(permissions: granted, health: health, globeAction: .doNothing,
                                        consumeGlobe: true, wisprFlow: false, model: .ready)
        #expect(issues == [health == .needsRelaunch ? .needsRelaunch : .stalePermission])
    }
    @Test func failedTapAndFlowAndModel() {
        let issues = SetupIssue.resolve(permissions: granted, health: .ready, globeAction: .doNothing,
                                        consumeGlobe: true, wisprFlow: true, model: .failed, globeActive: false)
        #expect(issues == [.globeInactive, .wisprFlow, .modelFailed])
        #expect(issues.allSatisfy { $0.hasAction })
    }
    @Test func preparingIsSpinnerOnly() {
        let issues = SetupIssue.resolve(permissions: granted, health: .ready, globeAction: .doNothing,
                                        consumeGlobe: true, wisprFlow: false, model: .preparing)
        #expect(issues == [.modelPreparing])
        #expect(!issues[0].hasAction)
    }
    @Test(arguments: [GlobeKeyConflict.unknown, .changeInputSource, .emojiAndSymbols, .startDictation])
    func globeActionOnlyWhenNotConsumed(_ action: GlobeKeyConflict) {
        for consumed in [true, false] {
            let issues = SetupIssue.resolve(permissions: granted, health: .ready, globeAction: action,
                                            consumeGlobe: consumed, wisprFlow: false, model: .ready)
            #expect(issues == (consumed ? [] : [.globeAction]))
        }
    }
}
