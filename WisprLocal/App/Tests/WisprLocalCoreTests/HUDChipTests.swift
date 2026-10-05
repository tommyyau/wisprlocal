import Testing
import AppKit
import Foundation
@testable import WisprLocalCore

/// Every chip is ONE line in the HUD: its text fits the notice text column (`HUDNoticeMetrics`:
/// 13 pt medium, monospaced digits, 360 pt max). The two long tips used to wrap to three lines.
@Suite struct HUDChipOneLineTests {
    static let maxText: CGFloat = 360
    static var font: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium) }

    static let chips: [String] = [
        PipelineNotice.didntCatchThat, PipelineNotice.didntCatchThatUseHeadset, PipelineNotice.micCuttingOut,
        PipelineNotice.focusChanged, PipelineNotice.pasteNotConfirmed,
        PipelineNotice.corrected, PipelineNotice.correctedCopyOnly, PipelineNotice.originalCopied,
        PipelineNotice.undoNotSafe, PipelineNotice.alreadyTyped, PipelineNotice.alreadyTypedNotSent,
        PipelineNotice.cancelled, PipelineNotice.escapeAgain(seconds: 42), PipelineNotice.recordingStopsIn(9),
        ChipCopy.indicatorHidden,
    ]

    @Test func everyChipFitsOneLine() {
        for text in Self.chips {
            let w = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
            #expect(w <= Self.maxText, "\(text): \(w) pt")
        }
    }

    @Test func micChipLinksToMicrophoneTab() throws {
        let url = HelpContentTests.repoRoot.appendingPathComponent("WisprLocal/App/Sources/WisprLocal/HUD.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let action = try #require(text.range(of: "case .micSettings:"))
        #expect(text[action.upperBound...].prefix(300).contains("settingsRequest = .tab(.microphone)"))
    }

    @Test func shortenedTips() {
        #expect(PipelineNotice.didntCatchThatUseHeadset == "Didn't catch that — a headset mic helps in loud places")
        #expect(PipelineNotice.micCuttingOut == "Mic cutting out — try turning off noise reduction")
        #expect(HUDChipPolicy.actions(for: PipelineNotice.didntCatchThatUseHeadset) == [.seeWhy])
        #expect(HUDChipPolicy.actions(for: PipelineNotice.micCuttingOut) == [.micSettings])
    }
}

/// HUD chip rules (DESIGN.md › "HUD chips"): one at a time, alert > undo > suggestion > info,
/// 8 s with a button, 3 s without.
@Suite struct HUDChipTests {
    typealias Q = HUDChipQueue
    let undo = HUDChipPolicy.chip(PipelineNotice.corrected)
    let add = HUDChipPolicy.chip(SmartDictionaryCopy.suggestion(Correction(misheard: "kuber netties", correct: "Kubernetes")))
    let alert = HUDChipPolicy.chip(PipelineNotice.focusChanged)
    let info = HUDChipPolicy.chip(PipelineNotice.cancelled)

    @Test func classificationAndTiming() {
        #expect(undo.priority == .undo && undo.actions == [.undoCorrection] && undo.seconds == 8)
        #expect(add.priority == .suggestion && add.actions == [.addWord, .notNow] && add.seconds == 8)
        #expect(alert.priority == .alert && alert.actions.isEmpty && alert.seconds == 3)
        #expect(info.priority == .info && info.seconds == 3)
        let hidden = HUDChipPolicy.chip(ChipCopy.indicatorHidden)
        #expect(hidden.priority == .info && hidden.actions == [.showIndicator] && hidden.seconds == 8)
        #expect(HUDChipPolicy.chip(PipelineNotice.didntCatchThat).priority == .alert)
        #expect(HUDChipPolicy.chip(PipelineNotice.didntCatchThat).actions == [.seeWhy])
        #expect(HUDChipPolicy.chip(PipelineNotice.micCuttingOut).priority == .alert)
        #expect(HUDChipPolicy.chip(PipelineNotice.escapeAgain(seconds: 42)).priority == .info)
        #expect(HUDChipPolicy.chip(PipelineNotice.recordingStopsIn(9)).priority == .info)
        #expect(HUDChipPolicy.chip(SmartDictionaryCopy.added("Kubernetes")).priority == .suggestion)
        #expect(HUDChipPolicy.chip("Disk full", priority: .alert).priority == .alert)
        #expect(HUDChipPolicy.chip("Disk full", priority: .alert).usesWarningTint)
        #expect(HUDChipPolicy.chip("Input Monitoring was turned off — open Settings", priority: .alert).usesWarningTint)
        #expect(!HUDChipPolicy.chip("Informational").usesWarningTint)
        // Every chip with a button gets the same time; the Undo window covers it.
        for a in HUDChipAction.allCases { #expect(!a.title.isEmpty) }
        #expect(PendingCorrection.hudSeconds == HUDChipPolicy.secondsWithButtons)
        #expect(PendingCorrection.window >= 2 * HUDChipPolicy.secondsWithButtons)
    }

    @Test func verbsAreShortSentenceCase() {
        #expect(HUDChipAction.allCases.map(\.title).allSatisfy { t in
            t.split(separator: " ").count <= 2 && t.first!.isUppercase && t.dropFirst().allSatisfy { !$0.isUppercase }
        })
        #expect(HUDChipAction.notNow.isPrimary == false)
        #expect(HUDChipAction.addWord.isPrimary && HUDChipAction.undoCorrection.isPrimary)
    }

    @Test func higherReplacesAndTheReplacedComesBack() {
        var q = Q()
        #expect(q.offer(undo, now: 0) == [.show(undo)])
        #expect(q.offer(alert, now: 1) == [.show(alert)])          // alert outranks Undo
        #expect(q.waiting?.chip == undo)
        #expect(q.tick(now: 3.9).isEmpty)
        #expect(q.tick(now: 4) == [.ended(alert), .show(undo)])     // Undo returns with the 7 s it had left
        #expect(q.nextDeadline == 11)
        #expect(q.tick(now: 11) == [.ended(undo)])
        #expect(q.current == nil)
    }

    @Test func lowerWaitsForItsTurnAndGetsItsFullTime() {
        var q = Q()
        _ = q.offer(undo, now: 0)
        #expect(q.offer(add, now: 0.5).isEmpty)                    // suggestion waits behind Undo
        #expect(q.current?.chip == undo)
        #expect(q.tick(now: 8) == [.ended(undo), .show(add)])       // never shown: the full 8 s
        #expect(q.nextDeadline == 16)
    }

    @Test func staleOrNearlySpentChipsAreDropped() {
        var q = Q()
        _ = q.offer(undo, now: 0)
        _ = q.offer(alert, now: 7)                                 // Undo parked with 1 s left
        #expect(q.tick(now: 10) == [.ended(alert), .ended(undo)])  // < 1.5 s: dropped, no flicker
        var r = Q()
        _ = r.offer(HUDChipPolicy.chip(PipelineNotice.didntCatchThat), now: 0)
        _ = r.offer(info, now: 0)
        _ = r.offer(HUDChipPolicy.chip(PipelineNotice.didntCatchThat), now: 7)  // same text: extended to 15
        #expect(r.nextDeadline == 10)                               // the waiting chip goes stale first
        #expect(r.tick(now: 10) == [.ended(info)])
        #expect(r.nextDeadline == 15)
    }

    @Test func sameTierLatestWinsAndSameTextExtends() {
        var q = Q()
        _ = q.offer(info, now: 0)
        let esc = HUDChipPolicy.chip(PipelineNotice.escapeAgain(seconds: 42))
        #expect(q.offer(esc, now: 1) == [.ended(info), .show(esc)])
        #expect(q.offer(esc, now: 2) == [.show(esc)])              // repeated: no flicker, just longer
        #expect(q.nextDeadline == 5)
        #expect(q.waiting == nil)
    }

    @Test func onlyTheHighestWaitingChipIsKept() {
        var q = Q()
        _ = q.offer(alert, now: 0)
        _ = q.offer(info, now: 0.1)
        #expect(q.offer(undo, now: 0.2) == [.ended(info)])         // Undo outranks the waiting info
        #expect(q.offer(add, now: 0.3) == [.ended(add)])           // suggestion loses to waiting Undo
        #expect(q.waiting?.chip == undo)
    }

    @Test func dismissAndClear() {
        var q = Q()
        _ = q.offer(alert, now: 0)
        _ = q.offer(add, now: 0)
        #expect(q.dismiss(text: add.text, now: 1) == [.ended(add)])   // waiting one dismissed quietly
        _ = q.offer(undo, now: 1)
        #expect(q.dismiss(text: alert.text, now: 1.5) == [.ended(alert), .show(undo)])
        #expect(q.clear() == [.ended(undo)])
        #expect(q.current == nil && q.waiting == nil && q.nextDeadline == nil)
    }
}
