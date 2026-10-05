@preconcurrency import FluidAudio
import Foundation

/// ASR model choice. Raw values match `BUNDLE_MODELS` tokens in `scripts/models_common.sh`.
/// Decision (2026-10-03): Parakeet TDT 0.6B v2 (English) is the DEFAULT; Parakeet Ultra
/// ships behind the "Noisy room / other languages" toggle (`AppSettings.noisyRoomMode`). Both are
/// bundled (`BUNDLE_MODELS` default "v2,ultra") and only the active one is loaded.
public enum ASRModelVariant: String, CaseIterable, Codable, Sendable, Identifiable {
    case parakeetUltra = "ultra"
    case parakeetV2 = "v2"

    public var id: String { rawValue }

    /// Standard mode (toggle OFF).
    public static let `default`: ASRModelVariant = .parakeetV2

    /// The model for the user's mode: Ultra with "Noisy room / other languages" ON, v2 otherwise.
    public static func forMode(noisyRoom: Bool) -> ASRModelVariant { noisyRoom ? .parakeetUltra : .parakeetV2 }

    public var displayName: String {
        switch self {
        case .parakeetUltra: return "Parakeet Ultra"
        case .parakeetV2: return "Parakeet TDT 0.6B v2"
        }
    }

    /// The mode's user-facing name (menu, Settings, docs all use exactly these).
    public var modeName: String {
        switch self {
        case .parakeetV2: return "English (Parakeet v2)"
        case .parakeetUltra: return "Noisy room / other languages (Parakeet Ultra)"
        }
    }

    /// Subtle status line for the menu footer and Settings › Microphone.
    public var modeLabel: String { "Speech: \(modeName)" }

    public var fluidVersion: AsrModelVersion {
        switch self {
        case .parakeetV2: return .v2
        case .parakeetUltra: return .ultra
        }
    }

    /// On-disk folder name, as FluidAudio names it (`Repo.<x>.folderName`). Kept in sync with
    /// `scripts/models_common.sh`; `ModelLocatorTests` asserts the mapping.
    public var folderName: String {
        switch self {
        case .parakeetV2: return Repo.parakeetV2.folderName
        case .parakeetUltra: return Repo.parakeetUltra.folderName
        }
    }
}

/// Installed apps use only bundled models. Dev/test search order: `$WISPRLOCAL_MODELS_DIR` (tests/dev; legacy `$WISPRLITE_MODELS_DIR`), app bundle
/// `Contents/Resources/Models`, then — only when the bundle has NO Models folder (dev runs) —
/// the legacy `~/Library/Application Support/WisprLocal/Models`.
public struct ModelLocator: Sendable {
    public var searchRoots: [URL]

    public init(searchRoots: [URL]) { self.searchRoots = searchRoots }

    public static let vadFolderName = "silero-vad"
    public static let vadModelFile = ModelNames.VAD.sileroVadFile

    public static var appSupportModelsDir: URL {
        AppPaths.appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    public static func standard(bundle: Bundle = .main,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                runningFromBundle: Bool? = nil) -> ModelLocator {
        var roots: [URL] = []
        let inApp = runningFromBundle ?? (bundle.bundleURL.pathExtension == "app")
        if !inApp, let env = AppEnvironment.value("MODELS_DIR", in: environment), !env.isEmpty { roots.append(URL(fileURLWithPath: env)) }
        let bundled = bundle.resourceURL?.appendingPathComponent("Models", isDirectory: true)
        if let bundled { roots.append(bundled) }
        // Legacy dev fallback ONLY when there is no bundled Models folder (e.g. `swift run`): an
        // installed app never reads App Support/Models (models exist once, in the bundle).
        var isDir: ObjCBool = false
        let hasBundled = bundled.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue } ?? false
        if !inApp, !hasBundled { roots.append(appSupportModelsDir) }
        return ModelLocator(searchRoots: roots)
    }

    public func asrDirectory(for variant: ASRModelVariant) -> URL? {
        firstExisting(variant.folderName) { dir in
            // Every variant ships a Decoder + Encoder .mlmodelc.
            ["Decoder.mlmodelc", "Encoder.mlmodelc"].allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
        }
    }

    public func vadModelURL() -> URL? {
        firstExisting(Self.vadFolderName) { dir in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.vadModelFile).path)
        }?.appendingPathComponent(Self.vadModelFile)
    }

    private func firstExisting(_ folder: String, valid: (URL) -> Bool) -> URL? {
        for root in searchRoots {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, valid(dir) {
                return dir
            }
        }
        return nil
    }
}

/// STRUCTURAL offline enforcement: every model load goes through `requireOffline()`, which
/// throws unless FluidAudio's `ModelHub.offlineMode` is on. `enableOfflineMode()` is called ONCE
/// at app launch (WisprLocalApp.init), before any FluidAudio use; loaders only assert.
public enum OfflinePolicy {
    public struct Violation: Error, LocalizedError {
        public var errorDescription: String? { "FluidAudio offline mode is off; refusing to load models (would allow network downloads)." }
    }

    public static func enableOfflineMode() { ModelHub.offlineMode = true }

    /// Throws `Violation` unless offline mode is on. `isOffline` is injectable for tests.
    public static func requireOffline(isOffline: () -> Bool = { ModelHub.offlineMode }) throws {
        guard isOffline() else { throw Violation() }
    }
}
