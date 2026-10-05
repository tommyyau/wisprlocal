import Testing
import Foundation

/// STRUCTURAL: model weights / build products must never be committed. Uses `git ls-files`;
/// skips when not in a git work tree or git is unavailable.
@Suite struct RepoHygieneTests {
    static let maxTrackedBytes = 50 * 1024 * 1024
    static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func git(_ args: [String]) -> (Int32, Data)? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return nil }
        let p = Foundation.Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", appRoot.path] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Forbidden tracked paths (pure; unit-tested below).
    static func violations(paths: [String], size: (String) -> Int) -> [String] {
        paths.compactMap { path in
            let comps = path.split(separator: "/").map(String.init)
            if comps.contains("Models") { return "\(path): inside a Models/ directory" }
            if comps.contains(where: { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }) { return "\(path): Core ML model" }
            if comps.contains(where: { $0.hasSuffix(".app") }) { return "\(path): app bundle" }
            let s = size(path)
            if s > maxTrackedBytes { return "\(path): \(s / 1_048_576) MB > 50 MB" }
            return nil
        }
    }

    @Test func noModelWeightsOrHugeFilesTracked() throws {
        guard let (status, top) = Self.git(["rev-parse", "--show-toplevel"]), status == 0 else { return }  // not a repo
        let root = String(decoding: top, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (s2, list) = Self.git(["-C", root, "ls-files", "-z"]), s2 == 0 else { return }
        let paths = list.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(paths.count > 10)
        let bad = Self.violations(paths: paths) { p in
            ((try? FileManager.default.attributesOfItem(atPath: root + "/" + p)[.size]) as? Int) ?? 0
        }
        #expect(bad.isEmpty, "tracked files that must not be committed: \(bad)")
    }

    @Test func gitignoreCoversWeightsAndBuilds() throws {
        guard let (status, top) = Self.git(["rev-parse", "--show-toplevel"]), status == 0 else { return }
        let root = String(decoding: top, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let gi = try String(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(".gitignore"), encoding: .utf8)
        for pattern in ["Models/", "*.mlmodelc", "build/", "*.app"] {
            #expect(gi.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == pattern }, "missing .gitignore pattern \(pattern)")
        }
    }

    /// Both bundled models (and the VAD) download only from a PINNED Hugging Face revision, and
    /// the dev model cache is never committed.
    @Test func everyBundledModelIsPinnedAndCacheIgnored() throws {
        let sh = try String(contentsOf: Self.appRoot.appendingPathComponent("scripts/models_common.sh"), encoding: .utf8)
        let fetcher = try String(contentsOf: Self.appRoot.appendingPathComponent("Tools/ModelFetcher/main.swift"), encoding: .utf8)
        for (env, repo) in [("WISPRLOCAL_REV_PARAKEET_V2", "FluidInference/parakeet-tdt-0.6b-v2-coreml"),
                            ("WISPRLOCAL_REV_PARAKEET_ULTRA", "FluidInference/parakeet-ultra-coreml"),
                            ("WISPRLOCAL_REV_SILERO_VAD", "FluidInference/silero-vad-coreml")] {
            #expect(sh.range(of: "export \(env)=\"[0-9a-f]{40}\"", options: .regularExpression) != nil, "\(env) not pinned to a commit")
            #expect(fetcher.contains(env) && fetcher.contains(repo), "fetcher ignores \(env)")
        }
        guard let (status, top) = Self.git(["rev-parse", "--show-toplevel"]), status == 0 else { return }
        let root = String(decoding: top, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        for folder in ["parakeet-tdt-0.6b-v2", "parakeet-ultra"] {
            let cache = Self.appRoot.appendingPathComponent(".models-cache")
            // Git refuses pathspecs beneath symlinks. A linked pre-populated cache must itself
            // be ignored; ordinary caches also prove the nested weights are ignored.
            let linked = (try? cache.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            let probe = linked ? cache.path : cache.appendingPathComponent("\(folder)/Encoder.mlmodelc/weights/weight.bin").path
            guard let (s, _) = Self.git(["-C", root, "check-ignore", "-q", probe]) else { return }
            #expect(s == 0, "\(probe) is not gitignored")
        }
    }

    /// U4: a STRUCTURAL gate nothing runs enforces nothing. `ci.sh` runs every gate script, and
    /// the build-time gate last (it rebuilds in release, so it goes after the fast checks).
    @Test func ciRunsEveryGateWithBuildTimeLast() throws {
        let ci = try String(contentsOf: Self.appRoot.appendingPathComponent("scripts/ci.sh"), encoding: .utf8)
        let steps = ci.split(separator: "\n").filter { $0.hasPrefix("echo \"### ") && !$0.contains("all green") }
        for gate in ["scripts/check_warnings.sh", "scripts/test_offline.sh", "scripts/check_build_time.sh"] {
            #expect(steps.contains { $0.contains(gate) }, "\(gate) is not run by ci.sh")
        }
        #expect(steps.last?.contains("scripts/check_build_time.sh") == true, "build-time gate is the last step")
    }

    @Test func violationRulesBite() {
        let v = Self.violations(paths: ["a/Models/x.json", "b/Encoder.mlmodelc/weights.bin", "c/WisprLite.app/Info.plist", "big.bin", "ok.swift"]) {
            $0 == "big.bin" ? 60 * 1_048_576 : 10
        }
        #expect(v.count == 4)
        #expect(!v.contains { $0.hasPrefix("ok.swift") })
    }
}
