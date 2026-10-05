import Testing
import Foundation
@testable import WisprLocalCore

@MainActor
final class FakePermissionProbe: PermissionProbe {
    var accessibilityGranted = false
    var inputMonitoringGranted = false
    /// Whether tap creation succeeds (independent of the grants, like a stale TCC entry).
    var tapCreatable = true
    private(set) var tapAttempts = 0
    private(set) var tapRunning = false

    func ensureEventTap() -> Bool {
        tapAttempts += 1
        if !tapRunning, tapCreatable, accessibilityGranted, inputMonitoringGranted { tapRunning = true }
        return tapRunning
    }
}

@Suite struct PermissionStateMachineTests {
    typealias M = PermissionStateMachine

    @Test func grantedAtLaunchWithTapIsReady() {
        var m = M()
        #expect(m.update(accessibility: true, inputMonitoring: true, tapRunning: true) == .ready)
        #expect(!m.sawMissing)
    }

    @Test func missingListsExactlyWhatToToggle() {
        var m = M()
        #expect(m.update(accessibility: false, inputMonitoring: false, tapRunning: false) == .missing([.accessibility, .inputMonitoring]))
        #expect(m.update(accessibility: true, inputMonitoring: false, tapRunning: false) == .missing([.inputMonitoring]))
        #expect(m.update(accessibility: false, inputMonitoring: true, tapRunning: false) == .missing([.accessibility]))
    }

    @Test func missingThenGrantedNeedsRelaunch() {
        var m = M()
        _ = m.update(accessibility: false, inputMonitoring: false, tapRunning: false)
        // Granted while running: relaunch, whether or not the tap happened to start.
        #expect(m.update(accessibility: true, inputMonitoring: true, tapRunning: false) == .needsRelaunch)
        #expect(m.update(accessibility: true, inputMonitoring: true, tapRunning: true) == .needsRelaunch)
        // Sticky for the life of the process.
        #expect(m.update(accessibility: true, inputMonitoring: true, tapRunning: true) == .needsRelaunch)
    }

    @Test func grantedButTapFailingIsStale() {
        var m = M()
        #expect(m.update(accessibility: true, inputMonitoring: true, tapRunning: false) == .stalePermission)
        #expect(m.health?.offersRelaunch == true)
        // Removing the stale entry (reads missing) and re-adding it → relaunch.
        #expect(m.update(accessibility: false, inputMonitoring: true, tapRunning: false) == .missing([.accessibility]))
        #expect(m.update(accessibility: true, inputMonitoring: true, tapRunning: false) == .needsRelaunch)
    }

    @Test func revokedWhileRunningGoesMissing() {
        var m = M()
        _ = m.update(accessibility: true, inputMonitoring: true, tapRunning: true)
        #expect(m.update(accessibility: true, inputMonitoring: false, tapRunning: true) == .missing([.inputMonitoring]))
    }

    @Test func guidanceIsSpecific() {
        let missing = PermissionHealth.missing([.inputMonitoring])
        #expect(missing.headline.contains("Input Monitoring"))
        #expect(!missing.headline.contains("Accessibility"))
        #expect(missing.instructions.count == 1)
        #expect(missing.instructions[0].contains("Privacy & Security › Input Monitoring"))
        #expect(PermissionHealth.needsRelaunch.headline == "Permissions updated — Relaunch WisprLocal")
        #expect(PermissionHealth.stalePermission.instructions.contains { $0.contains("−") && $0.contains("Accessibility") })
        #expect(PermissionHealth.stalePermission.instructions.contains { $0.contains("−") && $0.contains("Input Monitoring") })
        #expect(PermissionHealth.ready.instructions.isEmpty)
    }

    @Test func settingsDeepLinksTargetTheRightPanes() {
        #expect(Permission.accessibility.settingsURL.absoluteString.hasSuffix("?Privacy_Accessibility"))
        #expect(Permission.inputMonitoring.settingsURL.absoluteString.hasSuffix("?Privacy_ListenEvent"))
        #expect(Permission.accessibility.settingsURL.scheme == "x-apple.systempreferences")
    }
}

@Suite @MainActor struct PermissionMonitorTests {
    @Test func missingThenGrantedThenNeedsRelaunch() {
        let probe = FakePermissionProbe()
        let monitor = PermissionMonitor(probe: probe)
        var changes: [PermissionHealth] = []
        monitor.onChange = { changes.append($0) }
        monitor.start()
        #expect(monitor.health == .missing([.accessibility, .inputMonitoring]))
        #expect(monitor.isPolling)
        #expect(!monitor.tapRunning)

        probe.accessibilityGranted = true
        #expect(monitor.refresh() == .missing([.inputMonitoring]))
        probe.inputMonitoringGranted = true
        #expect(monitor.refresh() == .needsRelaunch)
        #expect(monitor.tapRunning)  // tap retried on every tick and came up
        #expect(changes == [.missing([.inputMonitoring]), .needsRelaunch])
        monitor.stopPolling()
    }

    @Test func grantedAtLaunchKeepsPolling() {
        let probe = FakePermissionProbe()
        probe.accessibilityGranted = true; probe.inputMonitoringGranted = true
        let monitor = PermissionMonitor(probe: probe)
        monitor.start()
        #expect(monitor.health == .ready)
        #expect(monitor.isPolling)
        #expect(monitor.tapRunning)
        monitor.stopPolling()
    }

    @Test func grantedButTapFailingShowsStaleHintAndKeepsPolling() {
        let probe = FakePermissionProbe()
        probe.accessibilityGranted = true; probe.inputMonitoringGranted = true
        probe.tapCreatable = false
        let monitor = PermissionMonitor(probe: probe)
        monitor.start()
        #expect(monitor.health == .stalePermission)
        #expect(monitor.isPolling)
        let before = probe.tapAttempts
        monitor.refresh()
        #expect(probe.tapAttempts == before + 1)  // keeps retrying the tap
        monitor.stopPolling()
        #expect(!monitor.isPolling)
    }
}

@Suite @MainActor struct PermissionRevocationTests {

    @Test func healthyThenRevokedAfterTwoNegativeReadsWithPollTolerance() {
        let probe = FakePermissionProbe()
        probe.accessibilityGranted = true; probe.inputMonitoringGranted = true
        let clock = PermissionTestClock()
        let monitor = PermissionMonitor(probe: probe, clock: { clock.now })
        monitor.start()
        defer { monitor.stopPolling() }
        probe.inputMonitoringGranted = false
        clock.now = 8.9; monitor.pollIfDue()
        #expect(monitor.health == .ready)
        clock.now = 10; monitor.pollIfDue()
        #expect(monitor.health == .ready)
        #expect(monitor.tapRunning)
        clock.now = 18.9; monitor.refresh()
        #expect(monitor.health == .ready)
        clock.now = 19; monitor.refresh()
        #expect(monitor.health == .missing([.inputMonitoring]))
        #expect(!monitor.tapRunning)
    }
    @Test func tapDisabledImmediatelyReprobes() {
        let probe = FakePermissionProbe()
        probe.accessibilityGranted = true; probe.inputMonitoringGranted = true
        let monitor = PermissionMonitor(probe: probe)
        monitor.start()
        defer { monitor.stopPolling() }
        let attempts = probe.tapAttempts
        probe.inputMonitoringGranted = false
        NotificationCenter.default.post(name: GlobeKeyMonitor.permissionHealthChanged, object: nil)
        #expect(probe.tapAttempts > attempts)
        #expect(monitor.health == .ready)
    }

    @Test func timerJitterStillReprobesUnhealthyPermissions() {
        let probe = FakePermissionProbe(), clock = PermissionTestClock()
        let monitor = PermissionMonitor(probe: probe, clock: { clock.now })
        monitor.start()
        defer { monitor.stopPolling() }
        let attempts = probe.tapAttempts
        for time in [2.1, 4.2, 6.3, 8.2, 10.3, 12.2] {
            clock.now = time
            monitor.pollIfDue()
        }
        #expect(probe.tapAttempts == attempts + 6)
    }

    @Test func revocationDebounceUsesPollTolerance() {
        var debounce = PermissionRevocationDebouncer()
        let read0 = debounce.confirmed(granted: false, at: 100)
        #expect(read0 == false)
        let read1 = debounce.confirmed(granted: false, at: 108.9)
        #expect(read1 == false)
        let read2 = debounce.confirmed(granted: false, at: 109)
        #expect(read2 == true)
        let read3 = debounce.confirmed(granted: true, at: 110)
        #expect(read3 == false)
        let read4 = debounce.confirmed(granted: false, at: 119)
        #expect(read4 == false)
    }

    @Test func sessionPermissionLossSurfacesNoticeAndAttention() {
        let health = PermissionHealth.missing([.inputMonitoring])
        #expect(health.lossNotice(previous: .ready) == "Input Monitoring was turned off — open Settings")
        #expect(PermissionHealth.stalePermission.lossNotice(previous: .ready) == nil)
        #expect(PermissionHealth.needsRelaunch.lossNotice(previous: .ready) == nil)
        #expect(PermissionHealth.stalePermission.offersRelaunch && PermissionHealth.needsRelaunch.offersRelaunch)
        #expect(PermissionHealth.missing([.accessibility, .inputMonitoring]).lossNotice(previous: .ready) ==
                "Accessibility and Input Monitoring were turned off — open Settings")
        #expect(health.lossNotice(previous: .missing([.inputMonitoring])) == nil)
        #expect(PermissionHealth.ready.lossNotice(previous: health) == nil)
        let issues = SetupIssue.resolve(permissions: Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, true) }),
                                        health: health, globeAction: .doNothing, consumeGlobe: true,
                                        wisprFlow: false, model: .ready)
        #expect(issues == [.permission(.inputMonitoring)])
        #expect(MenuAttention.resolve(MenuSnapshot(permissionNeeded: !health.isReady)) == .permissionNeeded)
        #expect(MenuBarIconState.resolve(MenuSnapshot(permissionNeeded: !health.isReady)) == .error)
    }

    @Test func transientRevocationResetsOnPositiveRead() {
        let probe = FakePermissionProbe()
        probe.accessibilityGranted = true; probe.inputMonitoringGranted = true
        let clock = PermissionTestClock()
        let monitor = PermissionMonitor(probe: probe, clock: { clock.now })
        monitor.start()
        defer { monitor.stopPolling() }
        probe.inputMonitoringGranted = false
        clock.now = 10; monitor.refresh()
        probe.inputMonitoringGranted = true
        clock.now = 20; monitor.refresh()
        #expect(monitor.health == .ready)
        probe.inputMonitoringGranted = false
        clock.now = 30; monitor.refresh()
        #expect(monitor.health == .ready)
        clock.now = 40; monitor.refresh()
        #expect(monitor.health == .missing([.inputMonitoring]))
    }

    @Test func healthyTimerActuallySchedulesTenSecondTicks() {
        let probe = FakePermissionProbe()
        probe.accessibilityGranted = true; probe.inputMonitoringGranted = true
        let clock = PermissionTestClock()
        let monitor = PermissionMonitor(probe: probe, clock: { clock.now })
        monitor.start()
        defer { monitor.stopPolling() }
        #expect(monitor.scheduledPollInterval == 10)
        let attempts = probe.tapAttempts
        for time in [2.0, 4, 6, 8, 8.9] { clock.now = time; monitor.pollIfDue() }
        #expect(probe.tapAttempts == attempts)
        clock.now = 10; monitor.pollIfDue()
        #expect(probe.tapAttempts == attempts + 1)
        probe.inputMonitoringGranted = false
        clock.now = 20; monitor.pollIfDue()
        clock.now = 30; monitor.pollIfDue()
        #expect(monitor.scheduledPollInterval == 2)
    }

}

@MainActor private final class PermissionTestClock { var now: TimeInterval = 0 }
