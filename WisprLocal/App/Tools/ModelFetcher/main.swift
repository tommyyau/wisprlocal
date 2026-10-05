// DEV-ONLY, ONLINE: one-time model download for scripts/fetch_models.sh.
// Deliberately lives outside Sources/ (and is never linked into WisprLocal.app), so the app's
// OfflineGuardTests scan stays clean. Usage: wisprlocal-fetch-models <destDir> <ultra|v2|vad>...
@preconcurrency import FluidAudio
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: wisprlocal-fetch-models <destDir> <ultra|v2|vad>...\n".utf8))
    exit(2)
}
let dest = URL(fileURLWithPath: args[0], isDirectory: true)
for token in args.dropFirst() where !["v2", "ultra", "vad"].contains(token) {
    FileHandle.standardError.write(Data("ERROR: unsupported model token \(token); use v2, ultra or vad\n".utf8))
    exit(2)
}
ModelHub.offlineMode = false
// Pin immutable revisions (set by scripts/models_common.sh). Unpinned downloads are refused for
// the shipped models so a mutable `main` can't silently change what gets bundled.
let env = ProcessInfo.processInfo.environment
var pins: [String: String] = [:]
if let r = env["WISPRLOCAL_REV_PARAKEET_ULTRA"], !r.isEmpty { pins["FluidInference/parakeet-ultra-coreml"] = r }
if let r = env["WISPRLOCAL_REV_PARAKEET_V2"], !r.isEmpty { pins["FluidInference/parakeet-tdt-0.6b-v2-coreml"] = r }
if let r = env["WISPRLOCAL_REV_SILERO_VAD"], !r.isEmpty { pins["FluidInference/silero-vad-coreml"] = r }
for (token, repo) in [("ultra", "FluidInference/parakeet-ultra-coreml"), ("v2", "FluidInference/parakeet-tdt-0.6b-v2-coreml"),
                      ("vad", "FluidInference/silero-vad-coreml")]
where args.dropFirst().contains(token) && pins[repo] == nil {
    FileHandle.standardError.write(Data("ERROR: no pinned revision for \(repo) (source scripts/models_common.sh)\n".utf8))
    exit(3)
}
ModelRegistry.revisionOverrides = pins
for (repo, rev) in pins { print("pinned \(repo) @ \(rev)") }
do {
    for token in args.dropFirst() {
        switch token {
        case "ultra": try await AsrModels.download(to: dest.appendingPathComponent(Repo.parakeetUltra.folderName), version: .ultra)
        case "v2": try await AsrModels.download(to: dest.appendingPathComponent(Repo.parakeetV2.folderName), version: .v2)
        case "vad": _ = try await ModelHub.loadModels(.vad, modelNames: [ModelNames.VAD.sileroVadFile], directory: dest)
        default: throw NSError(domain: "fetch", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown model \(token)"])
        }
        print("fetched \(token) -> \(dest.path)")
    }
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}
