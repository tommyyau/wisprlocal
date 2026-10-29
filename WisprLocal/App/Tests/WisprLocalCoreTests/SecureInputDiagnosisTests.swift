import AppKit
import Testing
@testable import WisprLocalCore

@Suite struct SecureInputDiagnosisTests {
    @Test func ownerComesFromCurrentConsoleSessionOnly() {
        let sessions: [[String: Any]] = [
            ["kCGSSessionOnConsoleKey": false, "kCGSSessionUserIDKey": 501, "kCGSSessionSecureInputPID": 90],
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 502, "kCGSSessionSecureInputPID": 91],
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501, "kCGSSessionSecureInputPID": 92]
        ]
        #expect(SecureInputDiagnosis.ownerPID(in: sessions, userID: 501) == 92)
        #expect(SecureInputDiagnosis.ownerPID(in: sessions, userID: 503) == nil)
    }

    @Test func missingAndInvalidOwnersRemainUnknown() {
        for pid: Any in [0, -1, Int64(Int32.max) + 1, "not a PID"] {
            let sessions: [[String: Any]] = [["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501,
                                            "kCGSSessionSecureInputPID": pid]]
            #expect(SecureInputDiagnosis.ownerPID(in: sessions, userID: 501) == nil)
        }
        #expect(SecureInputDiagnosis.ownerPID(in: [], userID: 501) == nil)
        let unknown = SecureInputDiagnosis(isActive: true)
        #expect(unknown.notice == PipelineNotice.secureInput)
        #expect(unknown.recoveryMessage.contains("An app"))
    }

    @Test func backgroundOwnerGetsActionableHelpWithoutAssertingPasswordFocus() {
        let d = SecureInputDiagnosis(isActive: true, ownerPID: 92, ownerName: "Sample Browser")
        #expect(d.notice == "Secure Input: Sample Browser")
        #expect(d.recoveryMessage.contains("across apps"))
        #expect(d.recoveryMessage.contains("restart Sample Browser"))
        #expect(!d.notice.contains("password field"))
        for text in [d.notice, PipelineNotice.secureInput, d.notice + " — stopped after typing 2 of 10 characters"] {
            let chip = HUDChipPolicy.chip(text)
            #expect(chip.priority == .alert && chip.actions == [.secureInputHelp] && chip.seconds == 8)
        }
    }

    @Test func clearedLockDiscardsStaleOwnerAndOffersRetry() {
        let d = SecureInputDiagnosis(isActive: false, ownerPID: 92, ownerName: "Sample Browser")
        #expect(d.ownerPID == nil && d.ownerName == nil)
        #expect(d.recoveryMessage.contains("try dictating again"))
        #expect(!d.recoveryMessage.contains("restart"))
    }

    @Test func longOwnerNamesFitTheNoticeColumn() {
        let d = SecureInputDiagnosis(isActive: true, ownerName: "  Very long\napplication name with many extra words  ")
        #expect(!d.notice.contains("\n") && d.notice.hasSuffix("…"))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        #expect((d.notice as NSString).size(withAttributes: [.font: font]).width <= 360)
    }
}

@MainActor @Suite struct SecureInputRecoveryTests {
    @Test func identifyingAnotherAppDoesNotBypassRecordingGate() async {
        let (e, p) = await makeEnv()
        e.secure.active = true
        e.secure.blockingNotice = SecureInputDiagnosis(isActive: true, ownerPID: 92, ownerName: "Sample Browser").notice
        p.handle(.startRecording)
        #expect(e.audio.started == 0 && !p.status.isRecording)
        #expect(e.notices == [e.secure.blockingNotice])
        e.secure.active = false
        p.handle(.startRecording)
        #expect(e.audio.started == 1 && p.status.isRecording)
        p.handle(.cancelRecording)
    }
}
