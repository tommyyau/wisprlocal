import AppKit
import Foundation

/// SEC-6: the pairing code IS the receiver's long-term key. When it has to travel through the
/// clipboard (Screen Sharing clipboard sync), it is written with the nspasteboard.org
/// Concealed + Transient markers (clipboard managers hide / skip it) and cleared again after
/// `clearAfter` unless the user copied something else meanwhile (`changeCount` guard). The
/// sender clears it after a successful pair (`clearIfHolding`).
@MainActor
public enum SecretPasteboard {
    public static let defaultClearAfter: Duration = .seconds(60)

    /// Writes `secret` and schedules the clear. Returns the clear task (tests await it).
    @discardableResult
    public static func write(_ secret: String, to pb: NSPasteboard = .general,
                             clearAfter: Duration = defaultClearAfter) -> Task<Bool, Never> {
        PrivatePasteboard.write(secret, to: pb, currentHostOnly: false)
        let written = pb.changeCount
        return Task { @MainActor in
            try? await Task.sleep(for: clearAfter)
            guard pb.changeCount == written else { return false }  // user copied something else
            pb.clearContents()
            return true
        }
    }

    /// Clears the pasteboard iff it still holds exactly `secret` (whitespace-trimmed compare).
    @discardableResult
    public static func clearIfHolding(_ secret: String, on pb: NSPasteboard = .general) -> Bool {
        let want = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty,
              pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == want else { return false }
        pb.clearContents()
        return true
    }
}
