@preconcurrency import AVFoundation
import Foundation
import Observation

/// One clip player (AVAudioPlayer in the app, a fake in tests).
@MainActor
public protocol ClipPlaying: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    /// Called once when the clip plays to the end.
    var onFinish: (@MainActor () -> Void)? { get set }
    func play() -> Bool
    func stop()
}

/// History playback: at most ONE clip plays at a time, local files from the recordings folder
/// only. Playback never competes with dictation: it refuses to start while one is in progress,
/// and the hotkey path calls `handleHotkey` BEFORE the pipeline, so pressing 🌐 stops it first.
/// It also stops when the window closes, the row is deleted, or its clip disappears.
@MainActor
@Observable
public final class ClipPlayback {
    /// Entry id whose clip is playing, nil when idle.
    public private(set) var playingID: UUID?
    @ObservationIgnored private var player: ClipPlaying?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let makePlayer: @MainActor (URL) throws -> ClipPlaying
    @ObservationIgnored private let isDictating: @MainActor () -> Bool

    public init(directory: URL, isDictating: @escaping @MainActor () -> Bool,
                makePlayer: @escaping @MainActor (URL) throws -> ClipPlaying = { try AVClipPlayer(url: $0) }) {
        self.directory = directory; self.isDictating = isDictating; self.makePlayer = makePlayer
    }

    /// 0…1 through the current clip (poll while playing).
    public var progress: Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return min(1, max(0, p.currentTime / p.duration))
    }

    public var duration: TimeInterval { player?.duration ?? 0 }

    public func isPlaying(_ id: UUID) -> Bool { playingID == id }

    /// A local `.wav` inside the recordings folder; anything else is refused.
    public func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension == "wav" else { return false }
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let file = url.standardizedFileURL.resolvingSymlinksInPath().path
        return file.hasPrefix(dir + "/")
    }

    /// Play/stop toggle for a row.
    public func toggle(id: UUID, url: URL) {
        if playingID == id { stop() } else { play(id: id, url: url) }
    }

    /// Stops whatever is playing, then plays `url`. Refused while a dictation is in progress.
    @discardableResult
    public func play(id: UUID, url: URL) -> Bool {
        stop()
        guard !isDictating(), accepts(url) else { return false }
        guard let p = try? makePlayer(url) else { return false }
        p.onFinish = { [weak self, weak p] in
            guard let self, let p, self.player === p else { return }
            self.stop()
        }
        guard p.play() else { return false }
        player = p
        playingID = id
        return true
    }

    public func stop() {
        player?.onFinish = nil
        player?.stop()
        player = nil
        playingID = nil
    }

    /// Row deleted.
    public func stop(ifPlaying id: UUID) { if playingID == id { stop() } }

    /// Clips changed on disk (Delete All, pruning): stop a clip that is gone.
    public func clipsChanged(available: Set<UUID>) {
        if let id = playingID, !available.contains(id) { stop() }
    }

    /// Hotkey actions arrive here BEFORE the pipeline: 🌐 pressed stops playback first.
    public func handleHotkey(_ action: HotkeyStateMachine.Action) {
        if action == .startRecording || action == .enterHandsFree { stop() }
    }
}

/// AVAudioPlayer on a local file (no streaming, no network URLs).
@MainActor
public final class AVClipPlayer: NSObject, ClipPlaying, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    public var onFinish: (@MainActor () -> Void)?

    public init(url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    public var duration: TimeInterval { player.duration }
    public var currentTime: TimeInterval { player.currentTime }
    public func play() -> Bool { player.play() }
    public func stop() { player.stop() }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?() }
    }
}
