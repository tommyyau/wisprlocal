import AppKit
import Carbon.HIToolbox
import IOKit

/// Explains the system-wide lock without assuming that the current field is a password.
/// Owner information is diagnostic only: it never weakens the recording or insertion gate.
public struct SecureInputDiagnosis: Equatable, Sendable {
    public let isActive: Bool
    public let ownerPID: Int32?
    public let ownerName: String?

    public init(isActive: Bool, ownerPID: Int32? = nil, ownerName: String? = nil) {
        self.isActive = isActive
        self.ownerPID = isActive ? ownerPID : nil
        let name = ownerName?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.ownerName = isActive && name?.isEmpty == false ? name : nil
    }

    public static let noticePrefix = "Secure Input: "
    public static let genericNotice = "Secure Input is blocking dictation"

    public var notice: String {
        guard let ownerName else { return Self.genericNotice }
        let short = ownerName.count > 26 ? String(ownerName.prefix(25)) + "…" : ownerName
        return Self.noticePrefix + short
    }

    public var recoveryMessage: String {
        guard isActive else { return "Secure Input has cleared. Click your text field and try dictating again." }
        let source = ownerName.map { "\($0) is holding macOS Secure Input." }
            ?? "An app is holding macOS Secure Input."
        let target = ownerName ?? "that app"
        return "\(source) This blocks dictation across apps; your current field does not have to be a password field.\n\n"
            + "In \(target), dismiss any password prompt and click a normal text field. If the lock remains, save your work and restart \(target). Terminals can also have Secure Keyboard Entry enabled.\n\n"
            + "WisprLocal can resume when macOS clears the lock. New dictation and insertion stay blocked while Secure Input is active."
    }

    /// Read only when showing a notice/help, never on the realtime audio or hotkey path.
    @MainActor public static func current() -> Self {
        guard IsSecureEventInputEnabled() else { return .init(isActive: false) }
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources")
        guard root != 0 else { return .init(isActive: true) }
        defer { IOObjectRelease(root) }
        let sessions = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] ?? []
        let pid = ownerPID(in: sessions, userID: getuid())
        let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return .init(isActive: true, ownerPID: pid, ownerName: name)
    }

    static func ownerPID(in sessions: [[String: Any]], userID: UInt32) -> Int32? {
        for session in sessions {
            guard session["kCGSSessionOnConsoleKey"] as? Bool == true,
                  let uid = session["kCGSSessionUserIDKey"] as? NSNumber, uid.uint32Value == userID,
                  let pid = session["kCGSSessionSecureInputPID"] as? NSNumber,
                  pid.int64Value > 0, pid.int64Value <= Int64(Int32.max) else { continue }
            return pid.int32Value
        }
        return nil
    }
}
