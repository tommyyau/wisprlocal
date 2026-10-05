import CryptoKit
import Foundation

/// The remote-viewer strategy chain (what `RoutingInserter` uses for `.remote`):
///   (a) the paired receiver matched to the viewer's window title (or the default receiver),
///       if it accepts the connection within 300 ms — the receiver pastes on the remote Mac;
///   (b) else the configured typing fallback (`RemoteConfig.typingFallback`).
/// It falls back only before transmission (`BridgeClientError.safeToFallBack`);
/// a sent-but-unacknowledged message (possible double insert) and every receiver refusal —
/// above all `secureInput` (password field focused on the remote Mac, SEC-4) — are final.
/// Never logs the key or the text.
public enum RemoteInsertionError: Error, LocalizedError, Equatable {
    /// The paired receiver refused: Secure Event Input is on there. The text was not inserted (the receiver refused it).
    case remoteSecureInput(String)
    public var errorDescription: String? {
        switch self { case .remoteSecureInput: return PipelineNotice.remoteSecureInput }
    }
}

@MainActor
public final class RemoteInserter: TextInserter {
    public var name: String { "remote" }
    /// Last route taken (status UI / tests): "receiver:<name>" or the fallback inserter's name.
    public private(set) var lastRoute: String?

    private let config: @MainActor () -> RemoteConfig
    private let receivers: @MainActor () -> [PairedReceiver]
    private let keyFor: @MainActor (UUID) -> SymmetricKey?
    private let sender: RemoteBridgeSending
    private let windowTitle: (@MainActor () -> String?)?
    private let focus: @MainActor () async -> FocusToken
    private let fallbackFor: @MainActor (RemoteTypingFallback, RemoteConfig) -> TextInserter
    private let connectTimeout: Duration

    public init(config: (@MainActor () -> RemoteConfig)? = nil,
                receivers: (@MainActor () -> [PairedReceiver])? = nil,
                keyFor: (@MainActor (UUID) -> SymmetricKey?)? = nil,
                sender: RemoteBridgeSending = BridgeClient(),
                windowTitle: (@MainActor () -> String?)? = nil,
                focus: (@MainActor () async -> FocusToken)? = nil,
                fallbackFor: (@MainActor (RemoteTypingFallback, RemoteConfig) -> TextInserter)? = nil,
                connectTimeout: Duration = BridgeClient.defaultConnectTimeout) {
        self.config = config ?? { RemoteConfigStore.shared.config }
        self.receivers = receivers ?? { PairedReceiverStore.shared.receivers }
        self.keyFor = keyFor ?? { PairedReceiverStore.shared.key(for: $0) }
        self.sender = sender
        self.windowTitle = windowTitle
        self.focus = focus ?? { await FocusProbe.current(full: true) }
        self.fallbackFor = fallbackFor ?? RemoteInserter.makeFallback
        self.connectTimeout = connectTimeout
    }

    public static func makeFallback(_ kind: RemoteTypingFallback, _ cfg: RemoteConfig) -> TextInserter {
        switch kind {
        case .unicode: return PacedTypingInserter(mode: .unicode)
        case .keycode: return PacedTypingInserter(mode: .keycode)
        case .clipboardDelay: return ClipboardDelayInserter(delay: .milliseconds(max(0, cfg.clipboardDelayMs)))
        }
    }

    public func insert(_ text: String) async throws {
        try await insert(text, prePostCheck: {})
    }

    public func insert(_ text: String, prePostCheck: @escaping @MainActor () throws -> Void) async throws {
        guard !text.isEmpty else { return }
        try prePostCheck()
        let target = await focus()
        try prePostCheck()
        try Task.checkCancellation()
        let cfg = config()
        let list = receivers()
        if !list.isEmpty,
           let r = ReceiverMatcher.match(windowTitle: windowTitle?() ?? target.windowTitle, receivers: list, defaultID: cfg.defaultReceiverID),
           let key = keyFor(r.id) {
            do {
                _ = try await sender.send(text, key: key, to: r.endpoint, connectTimeout: connectTimeout)
                lastRoute = "receiver:\(r.displayName)"
                Log.info("remote: inserted via receiver \(r.displayName)")
                return
            } catch let e as BridgeClientError {
                Log.info("remote: receiver \(r.displayName) → \(e.errorDescription ?? "error")")
                if e.isRemoteSecureInput {
                    lastRoute = "receiver-secure-input"
                    throw RemoteInsertionError.remoteSecureInput(r.displayName)
                }
                guard e.safeToFallBack else { lastRoute = "receiver-refused"; throw e }
            } catch {
                throw error
            }
        }
        try Task.checkCancellation()
        let now = await focus()
        try prePostCheck()
        guard now.matches(target) else { throw RemoteTypingError.focusChanged(typed: 0, of: text.count) }
        let fallback = fallbackFor(cfg.typingFallback, cfg)
        lastRoute = fallback.name
        Log.info("remote: typing fallback \(fallback.name)")
        if let guarded = fallback as? RemoteTargetInserter {
            try await guarded.insert(text, target: target, prePostCheck: prePostCheck)
        } else {
            try prePostCheck()
            try await fallback.insert(text)
        }
    }
}
