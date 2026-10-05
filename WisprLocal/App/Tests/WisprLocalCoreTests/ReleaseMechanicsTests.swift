import Foundation
import Testing

/// Script behavior checks: fixtures contain no real weights and never touch the model cache.
@Suite struct ReleaseMechanicsTests {
    private var appRoot: URL { RepoHygieneTests.appRoot }

    private func script(_ name: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent("scripts/\(name)"), encoding: .utf8)
    }

    private func run(_ path: URL, arguments: [String] = [], environment: [String: String] = [:]) throws -> (Int32, String) {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func modelManifestHasSortedCompleteSections() throws {
        let text = try script("model-manifest.sha256")
        let sections = text.components(separatedBy: "# model: ").dropFirst()
        #expect(sections.count == 3)
        for (section, expected) in zip(sections, [("parakeet-tdt-0.6b-v2", 22), ("parakeet-ultra", 20), ("silero-vad", 6)]) {
            let lines = section.split(separator: "\n").map(String.init)
            #expect(lines.first == expected.0)
            let entries = Array(lines.dropFirst())
            #expect(entries.count == expected.1)
            let paths = entries.map { String($0.dropFirst(66)) }
            #expect(paths == paths.sorted())
            #expect(Set(paths).count == paths.count)
            for entry in entries {
                #expect(entry.range(of: "^[0-9a-f]{64}  [^/].+$", options: .regularExpression) != nil)
                #expect(!entry.contains("../"))
            }
        }
    }

    @Test func modelVerifierRejectsChangedMissingExtraAndSymlinkFiles() throws {
        let root = appRoot.appendingPathComponent("build.noindex/model-check-\(UUID().uuidString)")
        let model = root.appendingPathComponent("models/silero-vad")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = root.appendingPathComponent("verify_models.sh")
        try FileManager.default.copyItem(at: appRoot.appendingPathComponent("scripts/verify_models.sh"), to: verifier)
        try "# model: silero-vad\nba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  payload.bin\n"
            .write(to: root.appendingPathComponent("model-manifest.sha256"), atomically: true, encoding: .utf8)
        let payload = model.appendingPathComponent("payload.bin")
        let arguments = [root.appendingPathComponent("models").path, "silero-vad"]
        let env = ["WISPRLOCAL_SKIP_MODEL_VERIFY": "0"]
        try "abc".write(to: payload, atomically: true, encoding: .utf8)
        #expect(try run(verifier, arguments: arguments, environment: env).0 == 0)
        try "changed".write(to: payload, atomically: true, encoding: .utf8)
        let changed = try run(verifier, arguments: arguments, environment: env)
        #expect(changed.0 != 0 && changed.1.contains("payload.bin: FAILED"))
        try FileManager.default.removeItem(at: payload)
        let missing = try run(verifier, arguments: arguments, environment: env)
        #expect(missing.0 != 0 && missing.1.contains("Missing files") && missing.1.contains("payload.bin"))
        try "abc".write(to: payload, atomically: true, encoding: .utf8)
        let rootExtra = root.appendingPathComponent("models/stray.bin")
        try "stray".write(to: rootExtra, atomically: true, encoding: .utf8)
        let rootStrict = try run(verifier, arguments: arguments, environment: env)
        #expect(rootStrict.0 != 0 && rootStrict.1.contains("stray.bin"))
        #expect(try run(verifier, arguments: ["--allow-extra"] + arguments, environment: env).0 == 0)
        try FileManager.default.removeItem(at: rootExtra)
        let extra = model.appendingPathComponent("extra.bin")
        try "extra".write(to: extra, atomically: true, encoding: .utf8)
        let strict = try run(verifier, arguments: arguments, environment: env)
        #expect(strict.0 != 0 && strict.1.contains("Extra files") && strict.1.contains("extra.bin"))
        let cache = try run(verifier, arguments: ["--allow-extra"] + arguments, environment: env)
        #expect(cache.0 == 0 && cache.1.contains("WARNING") && cache.1.contains("extra.bin"))
        // Exercise fetch_models.sh with an already-populated tiny cache; no network/download.
        for name in ["fetch_models.sh", "models_common.sh"] {
            try FileManager.default.copyItem(at: appRoot.appendingPathComponent("scripts/\(name)"), to: root.appendingPathComponent(name))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: verifier.path)
        let fetched = try run(root.appendingPathComponent("fetch_models.sh"), arguments: [arguments[0]], environment: env.merging(["BUNDLE_MODELS": "vad"]) { _, new in new })
        #expect(fetched.0 == 0 && fetched.1.contains("WARNING") && fetched.1.contains("extra.bin"))
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: payload)
        let symlink = try run(verifier, arguments: arguments, environment: env)
        #expect(symlink.0 != 0 && symlink.1.contains("symlink inside the model folder") && symlink.1.contains("extra.bin"))
        let skipped = try run(verifier, arguments: arguments, environment: ["WISPRLOCAL_SKIP_MODEL_VERIFY": "1"])
        #expect(skipped.0 == 0 && skipped.1.contains("WARNING"))
        try FileManager.default.removeItem(at: extra)
        let resolved = root.appendingPathComponent("resolved-model")
        try FileManager.default.moveItem(at: model, to: resolved)
        try FileManager.default.createSymbolicLink(at: model, withDestinationURL: resolved)
        let linkedFolder = try run(verifier, arguments: arguments, environment: env)
        #expect(linkedFolder.0 == 0 && linkedFolder.1.contains("model folder is itself a symlink"))
        try FileManager.default.createSymbolicLink(at: resolved.appendingPathComponent("internal-link"), withDestinationURL: payload)
        #expect(try run(verifier, arguments: arguments, environment: env).0 != 0)
        try FileManager.default.removeItem(at: resolved.appendingPathComponent("internal-link"))
        for name in ["LICENSE", "NOTICE"] {
            try "credit".write(to: model.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        #expect(try run(verifier, arguments: arguments, environment: env).0 == 0)
        #expect(try run(verifier, arguments: [root.appendingPathComponent("models").path, "parakeet-ultra"], environment: env).0 != 0)
    }

    @Test func modelVerifierPrintsOnlySummariesAndFailingFiles() throws {
        let root = appRoot.appendingPathComponent("build.noindex/model-output-\(UUID().uuidString)")
        let models = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = root.appendingPathComponent("verify_models.sh")
        try FileManager.default.copyItem(at: appRoot.appendingPathComponent("scripts/verify_models.sh"), to: verifier)
        let folders = ["parakeet-tdt-0.6b-v2", "parakeet-ultra", "silero-vad"]
        let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        var manifest = ""
        for folder in folders {
            let model = models.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            manifest += "# model: \(folder)\n"
            for file in ["payload.bin", "unchanged.bin"] {
                try "abc".write(to: model.appendingPathComponent(file), atomically: true, encoding: .utf8)
                manifest += "\(hash)  \(file)\n"
            }
        }
        try manifest.write(to: root.appendingPathComponent("model-manifest.sha256"), atomically: true, encoding: .utf8)
        let env = ["WISPRLOCAL_SKIP_MODEL_VERIFY": "0"]
        let success = try run(verifier, arguments: [models.path], environment: env)
        #expect(success.0 == 0)
        #expect(!success.1.contains(": OK"))
        let lines = success.1.split(separator: "\n").map(String.init)
        #expect(lines.count == folders.count)
        for folder in folders {
            #expect(lines.filter { $0 == "OK: \(folder) (2 files, SHA-256 verified)" }.count == 1)
        }
        try "changed".write(to: models.appendingPathComponent("silero-vad/payload.bin"), atomically: true, encoding: .utf8)
        let failure = try run(verifier, arguments: [models.path, "silero-vad"], environment: env)
        #expect(failure.0 != 0 && failure.1.contains("payload.bin: FAILED"))
        #expect(failure.1.contains("ERROR: model verification: SHA-256 mismatch for silero-vad"))
        #expect(!failure.1.contains("unchanged.bin") && !failure.1.contains(": OK"))
    }

    @Test func buildersHardenAndVerifyAfterSigning() throws {
        for name in ["build_app.sh", "build_receiver.sh", "make_release.sh"] {
            let text = try script(name)
            #expect(text.contains("--options runtime --timestamp=none"))
            #expect(text.contains("source \"$HERE/version_common.sh\""))
        }
        for name in ["build_app.sh", "build_receiver.sh"] {
            let text = try script(name)
            let sign = try #require(text.range(of: "if ! codesign --force"))
            let verify = try #require(text.range(of: "\"$HERE/verify_bundle.sh\" \"$APP\""))
            #expect(sign.lowerBound < verify.lowerBound)
        }
        let entitlements = try Data(contentsOf: appRoot.appendingPathComponent("Resources/WisprLocal.entitlements"))
        let plist = try #require(PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Bool])
        #expect(plist == ["com.apple.security.device.audio-input": true])
        let release = try script("make_release.sh")
        #expect(release.contains("APP_CERT") && release.contains("certificate_hash receiver"))
        #expect(release.contains("WISPRLOCAL_ALLOW_ADHOC"))
        #expect(release.contains("-adhoc-dryrun") && release.contains("NOT A RELEASE"))
        #expect(release.contains("[ \"$VERSION\" = \"$RELEASE_VERSION\" ]"))
        let identity = try script("create_signing_identity.sh")
        #expect(identity.contains("-f pkcs12 -x -P") && identity.contains("-T /usr/bin/codesign"))
        #expect(!identity.contains("export P12_PASS"))
        #expect(identity.contains("${TMPDIR:-/tmp}/wisprlocal-signing.XXXXXX"))
        #expect(identity.contains("briefly visible to same-user processes"))
        #expect(identity.contains("trap 'exit 130' INT") && identity.contains("trap 'exit 143' TERM"))
        #expect(identity.contains("-passout \"file:$WORK/passphrase\""))
    }

    @Test func certificateHashExtractsSystemBinaryCertificate() throws {
        let harness = appRoot.appendingPathComponent("build.noindex/certificate-check-\(UUID().uuidString).sh")
        try FileManager.default.createDirectory(at: harness.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: harness) }
        try "set -euo pipefail\nsource \"$APP_DIR/scripts/signing_common.sh\"\ncertificate_hash system /bin/ls\n"
            .write(to: harness, atomically: true, encoding: .utf8)
        let result = try run(harness, environment: ["APP_DIR": appRoot.path])
        #expect(result.0 == 0)
        #expect(result.1.range(of: "^[0-9a-f]{64}\\n$", options: .regularExpression) != nil)
    }

    @Test func unsignedCertificateFailureCleansTemporaryDirectory() throws {
        let root = appRoot.appendingPathComponent("build.noindex/unsigned-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("unsigned")
        try "unsigned fixture".write(to: input, atomically: true, encoding: .utf8)
        let harness = root.appendingPathComponent("check.sh")
        try "set -euo pipefail\nsource \"$APP_DIR/scripts/signing_common.sh\"\ncertificate_hash unsigned \"$INPUT\"\n"
            .write(to: harness, atomically: true, encoding: .utf8)
        let result = try run(harness, environment: ["APP_DIR": appRoot.path, "INPUT": input.path, "TMPDIR": root.path])
        #expect(result.0 != 0 && result.1.contains("ERROR: missing signing certificate"))
        #expect(!result.1.contains("unbound variable"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("wisprlocal-cert.") })
    }

    @Test func bundleVerifierRejectsExtraModelFile() throws {
        let root = appRoot.appendingPathComponent("build.noindex/bundle-check-\(UUID().uuidString)")
        let fixtureApp = root.appendingPathComponent("repo/WisprLocal/App")
        let scripts = fixtureApp.appendingPathComponent("scripts")
        let bundle = root.appendingPathComponent("Fixture.app")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let model = resources.appendingPathComponent("Models/silero-vad")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["verify_bundle.sh", "verify_models.sh"] {
            let target = scripts.appendingPathComponent(name)
            try FileManager.default.copyItem(at: appRoot.appendingPathComponent("scripts/\(name)"), to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        try FileManager.default.copyItem(at: appRoot.appendingPathComponent("Licenses"), to: fixtureApp.appendingPathComponent("Licenses"))
        try FileManager.default.copyItem(at: fixtureApp.appendingPathComponent("Licenses"), to: resources.appendingPathComponent("Licenses"))
        let ack = appRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ACKNOWLEDGEMENTS.md")
        try FileManager.default.copyItem(at: ack, to: root.appendingPathComponent("repo/ACKNOWLEDGEMENTS.md"))
        try FileManager.default.copyItem(at: ack, to: resources.appendingPathComponent("Licenses/ACKNOWLEDGEMENTS.md"))
        for name in ["LICENSE", "NOTICE"] {
            try FileManager.default.copyItem(at: fixtureApp.appendingPathComponent("Licenses/silero-vad/\(name)"), to: model.appendingPathComponent(name))
        }
        try "# model: silero-vad\nba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  payload.bin\n"
            .write(to: scripts.appendingPathComponent("model-manifest.sha256"), atomically: true, encoding: .utf8)
        try "abc".write(to: model.appendingPathComponent("payload.bin"), atomically: true, encoding: .utf8)
        try "extra".write(to: model.appendingPathComponent("download-metadata.json"), atomically: true, encoding: .utf8)
        let result = try run(scripts.appendingPathComponent("verify_bundle.sh"), arguments: [bundle.path], environment: ["WISPRLOCAL_SKIP_MODEL_VERIFY": "0"])
        #expect(result.0 != 0)
        #expect(result.1.contains("Extra files") && result.1.contains("download-metadata.json"))
        #expect(result.1.contains("file inventory differs"))
    }

    @Test func versionDefaultsAndExperimentalOverrideWarning() throws {
        let harness = appRoot.appendingPathComponent("build.noindex/version-check-\(UUID().uuidString).sh")
        try FileManager.default.createDirectory(at: harness.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: harness) }
        try "source \"$APP_DIR/scripts/version_common.sh\"\nprintf '%s\\n' \"$VERSION\"\n"
            .write(to: harness, atomically: true, encoding: .utf8)
        let expected = try String(contentsOf: appRoot.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let normal = try run(harness, environment: ["APP_DIR": appRoot.path, "VERSION": ""])
        #expect(normal.0 == 0 && normal.1 == expected + "\n")
        let overridden = try run(harness, environment: ["APP_DIR": appRoot.path, "VERSION": "9.8.7"])
        #expect(overridden.0 == 0 && overridden.1.contains("WARNING") && overridden.1.hasSuffix("9.8.7\n"))
    }

    @Test func ciAndIgnoresCoverReleaseHygiene() throws {
        let root = appRoot.deletingLastPathComponent().deletingLastPathComponent()
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"), encoding: .utf8)
        for gate in ["push", "pull_request", "macos-26", "Xcode_2[6-9]*.app", "swift build", "swift test", "scripts/check_warnings.sh", "scripts/privacy_scan.sh"] {
            #expect(workflow.contains(gate))
        }
        #expect(!workflow.contains("fetch_models.sh"))
        #expect(workflow.contains("grep -Eiv 'beta|release[ _-]*candidate|[ _-]RC([ _.-]|$)'"))
        #expect(workflow.contains("using runner default"))
        for location in [root, appRoot] {
            let ignore = try String(contentsOf: location.appendingPathComponent(".gitignore"), encoding: .utf8)
            for pattern in ["DerivedData/", ".swiftpm/", "xcuserdata/", "*.xcuserstate", ".DS_Store"] {
                #expect(ignore.split(separator: "\n").contains(Substring(pattern)))
            }
        }
    }

}
