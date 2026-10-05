import Testing
import Foundation
@testable import WisprLocalCore

/// Engine whose prepare always fails (model switch failure path).
final class FailingTranscriber: Transcriber, Sendable {
    struct Failure: LocalizedError { var errorDescription: String? { "model files missing" } }
    var engineName: String { "fluidaudio:broken" }
    func prepare() async throws { throw Failure() }
    func transcribe(_ samples: [Float], vocabularyHints: [String]) async throws -> String { "" }
    func reset() async {}
    func unload() async {}
}

/// Menu attention row + menu-bar icon derived from live state (`MenuModel`).
@Suite struct MenuModelTests {
    static let everything = MenuSnapshot(permissionNeeded: true, holdingOffForWisprFlow: true, modelFailed: true,
                                         modelLoading: true, recording: true,
                                         micReady: .window(secondsLeft: 42), indicatorHidden: true)

    @Test func permissionAttentionOpensSetupWithoutSelectingATab() throws {
        #expect(MenuAttention.permissionNeeded.action == .openSetup)
        let url = HelpContentTests.repoRoot.appendingPathComponent("WisprLocal/App/Sources/WisprLocal/MenuContent.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let action = try #require(text.range(of: "case .openSetup:"))
        #expect(text[action.upperBound...].prefix(300).contains("settingsRequest = .setup"))
    }

    @Test func allPermissionProblemsKeepMenuAttention() {
        for health in [PermissionHealth.missing([.inputMonitoring]), .stalePermission, .needsRelaunch] {
            let snapshot = MenuSnapshot(permissionNeeded: !health.isReady)
            #expect(MenuAttention.resolve(snapshot) == .permissionNeeded)
        }
    }

    @Test func normalReadyStateHasNoAttentionRowAndNoLeadingSeparator() {
        #expect(MenuAttention.resolve(MenuSnapshot()) == nil)
        let e = MenuModel.entries(MenuSnapshot(), noisyRoom: false)
        #expect(e == [.openApp, .settings, .separator, .noisyRoom(checked: false), .separator,
                      .help([.helpAndFAQ, .gettingStarted, .credits, .about]), .separator, .quit])
        #expect(!e.map(\.title).contains { $0.localizedCaseInsensitiveContains("ready") })
    }

    @Test func attentionPriorityIsPermissionWisprFlowModelFailureLoadingRecordingHiddenMicReady() {
        var s = Self.everything
        var order: [MenuAttention] = []
        while let a = MenuAttention.resolve(s) {
            order.append(a)
            switch a {
            case .permissionNeeded: s.permissionNeeded = false
            case .holdingOffForWisprFlow: s.holdingOffForWisprFlow = false
            case .modelFailed: s.modelFailed = false
            case .loadingModel: s.modelLoading = false
            case .recording: s.recording = false
            case .indicatorHidden: s.indicatorHidden = false
            case .micReady: s.micReady = nil
            }
        }
        #expect(order == [.permissionNeeded, .holdingOffForWisprFlow, .modelFailed, .loadingModel, .recording,
                          .indicatorHidden, .micReady(.window(secondsLeft: 42))])
        // Each state alone shows itself.
        #expect(MenuAttention.resolve(MenuSnapshot(micReady: .always, indicatorHidden: true)) == .indicatorHidden)
        #expect(MenuAttention.resolve(MenuSnapshot(recording: true, indicatorHidden: true)) == .recording)
        #expect(MenuAttention.resolve(MenuSnapshot(holdingOffForWisprFlow: true, modelLoading: true)) == .holdingOffForWisprFlow)
    }

    @Test func attentionRowCopyIsTitleCaseWithInlineAction() {
        #expect(MenuAttention.micReady(.window(secondsLeft: 42)).label == "Mic Ready · 0:42 — Stop")
        #expect(MenuAttention.micReady(.window(secondsLeft: 60)).label == "Mic Ready · 1:00 — Stop")
        #expect(MenuAttention.micReady(.always).label == "Mic Ready — Stop")
        #expect(MenuAttention.indicatorHidden.label == "Indicator Hidden — Show")
        #expect(MenuAttention.holdingOffForWisprFlow.label == "Wispr Flow Is Active — Use WisprLocal Anyway…")
        #expect(MenuAttention.holdingOffForWisprFlow.actionTitle == "Use WisprLocal Anyway…")
        #expect(MenuAttention.permissionNeeded.label == "Permission Needed — Fix…")
        #expect(MenuAttention.loadingModel.label == "Loading Speech Model…" && MenuAttention.loadingModel.action == nil)
        #expect(MenuAttention.recording.label == "Recording…" && MenuAttention.recording.action == nil)
        #expect(MenuAttention.clock(-3) == "0:00")
    }

    /// Every attention row stays short: at most 40 characters before the dash.
    @Test func attentionRowsStayShort() {
        let all: [MenuAttention] = [.permissionNeeded, .holdingOffForWisprFlow, .modelFailed, .loadingModel, .recording,
                                    .indicatorHidden, .micReady(.always), .micReady(.window(secondsLeft: 599))]
        for a in all {
            #expect(a.title.count <= 40, "\(a.title)")
            #expect(!a.title.contains("—"), "the dash separates title and action only: \(a.title)")
            #expect(a.label.count <= 64, "\(a.label)")
        }
    }

    @Test func entriesFollowTheAgreedOrder() {
        let e = MenuModel.entries(MenuSnapshot(micReady: .window(secondsLeft: 9)), noisyRoom: true)
        #expect(e == [
            .attention(.micReady(.window(secondsLeft: 9))), .separator,
            .openApp, .settings,
            .separator,
            .noisyRoom(checked: true),
            .separator,
            .help([.helpAndFAQ, .gettingStarted, .credits, .about]),
            .separator,
            .quit,
        ])
        #expect(e.map(\.title).filter { !$0.isEmpty } == [
            "Mic Ready · 0:09 — Stop", "Open Dashboard", "Settings…", "Noisy Room Mode", "Help", "Quit WisprLocal"])
        #expect(MenuModel.noisyRoomSubtitle == "Also understands 25 European languages")
        #expect(MenuEntry.HelpItem.allCases.map(\.title) == ["Help & FAQ…", "Getting Started…", "Credits…", "About WisprLocal…"])
        #expect(MenuEntry.settings.keyEquivalent == "," && MenuEntry.quit.keyEquivalent == "q")
        // No speech-model footer, no emoji anywhere.
        let all = e.map(\.title).joined()
        #expect(!all.contains("Speech:"))
        #expect(!all.unicodeScalars.contains { $0.properties.isEmojiPresentation })
    }

    @Test func removedCopyPauseAndIndicatorActionsDoNotReturn() {
        for snapshot in [MenuSnapshot(), Self.everything, MenuSnapshot(indicatorHidden: true)] {
            let entries = MenuModel.entries(snapshot, noisyRoom: true)
            for entry in entries {
                switch entry {
                case .attention, .openApp, .settings, .separator, .noisyRoom, .help, .quit: break
                }
            }
            let titles = entries.map(\.title)
            #expect(!titles.contains("Copy Last Dictation"))
            #expect(!titles.contains("Pause Dictation") && !titles.contains("Resume Dictation"))
            #expect(!titles.contains("Hide Indicator for 1 Hour") && !titles.contains("Show Indicator"))
        }
    }

    @Test func iconStateMapping() {
        #expect(MenuBarIconState.resolve(MenuSnapshot()) == .idle)
        #expect(MenuBarIconState.resolve(MenuSnapshot(modelLoading: true)) == .idle)
        #expect(MenuBarIconState.resolve(MenuSnapshot(micReady: .always)) == .warmMic)
        #expect(MenuBarIconState.resolve(MenuSnapshot(micReady: .window(secondsLeft: 3))) == .warmMic)
        #expect(MenuBarIconState.resolve(MenuSnapshot(recording: true, micReady: .always)) == .recording)
        #expect(MenuBarIconState.resolve(MenuSnapshot(holdingOffForWisprFlow: true, recording: true)) == .holdingOff)
        #expect(MenuBarIconState.resolve(MenuSnapshot(modelFailed: true)) == .error)
        #expect(MenuBarIconState.resolve(MenuSnapshot(permissionNeeded: true)) == .error)
        #expect(MenuBarIconState.resolve(Self.everything) == .error)
        #expect(MenuBarIconState.error.resourceName == "MenuBarIconAlert")
        #expect(MenuBarIconState.idle.resourceName == "MenuBarIcon")
    }

    /// Every state's glyph ships (1x + 2x template PNGs in Resources/, copied by build_app.sh).
    @Test func everyIconStateHasItsGlyph() {
        let res = HelpContentTests.repoRoot.appendingPathComponent("WisprLocal/App/Resources")
        #expect(MenuBarIconState.allCases == [.idle, .warmMic, .recording, .holdingOff, .error])
        #expect(Set(MenuBarIconState.allCases.map(\.resourceName)).count == MenuBarIconState.allCases.count)
        for s in MenuBarIconState.allCases {
            for suffix in [".png", "@2x.png"] {
                let f = res.appendingPathComponent(s.resourceName + suffix)
                #expect(FileManager.default.fileExists(atPath: f.path), "\(f.lastPathComponent)")
            }
        }
    }
}

/// BUG: the menu kept "Switching to Noisy room model…" after the switch finished. The status is
/// now derived from the pipeline's model state, so it clears on success, failure and A→B→A.
@Suite struct ModelSwitchStatusTests {
    @MainActor static func snapshot(_ p: DictationPipeline) -> MenuSnapshot {
        MenuSnapshot(modelFailed: p.modelError != nil, modelLoading: p.isModelLoading, recording: p.status.isRecording)
    }

    @Test @MainActor func clearsOnSuccess() async {
        let v2 = ModeTranscriber("v2"), ultra = ModeTranscriber("ultra", gatedPrepare: true)
        let (_, p) = await makeModeEnv(v2)
        #expect(MenuAttention.resolve(Self.snapshot(p)) == nil)
        let task = p.switchTranscriber(to: ultra)
        #expect(MenuAttention.resolve(Self.snapshot(p)) == .loadingModel)
        await ultra.open()
        await task.value
        #expect(!p.isModelLoading && p.modelReady)
        #expect(MenuAttention.resolve(Self.snapshot(p)) == nil, "no stale switching status once the model is ready")
    }

    @Test @MainActor func clearsOnFailure() async {
        let (_, p) = await makeModeEnv(ModeTranscriber("v2"))
        await p.switchTranscriber(to: FailingTranscriber()).value
        #expect(!p.isModelLoading)
        #expect(p.modelError == "model files missing")
        #expect(MenuAttention.resolve(Self.snapshot(p)) == .modelFailed, "failure replaces the loading status")
        #expect(MenuBarIconState.resolve(Self.snapshot(p)) == .error)
        // Switching away from the broken engine recovers fully.
        await p.switchTranscriber(to: ModeTranscriber("ultra")).value
        #expect(p.modelReady && MenuAttention.resolve(Self.snapshot(p)) == nil)
    }

    @Test @MainActor func rapidDoubleSwitchEndsOnTheFirstEngineWithNoStaleStatus() async {
        let v2 = ModeTranscriber("v2"), ultra = ModeTranscriber("ultra", gatedPrepare: true)
        let (e, p) = await makeModeEnv(v2)
        p.switchTranscriber(to: ultra)
        let back = p.switchTranscriber(to: v2)
        #expect(MenuAttention.resolve(Self.snapshot(p)) == .loadingModel)
        await back.value
        #expect(p.transcriber.engineName == "fluidaudio:v2" && v2.loaded && !ultra.loaded && ultra.prepares == 0)
        #expect(p.modelReady && !p.isModelLoading)
        #expect(MenuAttention.resolve(Self.snapshot(p)) == nil)
        p.handle(.startRecording); p.handle(.commitRecording); await p.drain()
        #expect(e.history.entries.last?.engine == "fluidaudio:v2")
    }

    /// A→B→A while B is already mid-load: B's late completion must not mark the model ready or
    /// leave a status behind; A ends up loaded and ready.
    @Test @MainActor func doubleSwitchWhileTheMiddleEngineIsLoading() async {
        let v2 = ModeTranscriber("v2"), ultra = ModeTranscriber("ultra", gatedPrepare: true)
        let (_, p) = await makeModeEnv(v2)
        p.switchTranscriber(to: ultra)
        while ultra.prepares == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let back = p.switchTranscriber(to: v2)
        #expect(MenuAttention.resolve(Self.snapshot(p)) == .loadingModel)
        await ultra.open()
        await back.value
        #expect(p.transcriber.engineName == "fluidaudio:v2" && v2.loaded && !ultra.loaded)
        #expect(p.modelReady && !p.isModelLoading)
        #expect(MenuAttention.resolve(Self.snapshot(p)) == nil)
    }
}
