import Testing
import Foundation
import FluidAudio
@testable import WisprLocalCore

/// STRUCTURAL: every model the build bundles (BUNDLE_MODELS default in scripts/models_common.sh,
/// plus the Silero VAD and FluidAudio) has a licence file to ship in Contents/Resources/Licenses.
/// build_app.sh refuses to build without them; this test fails first.
@Suite struct LicenseTests {
    static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var licenses: URL { appRoot.appendingPathComponent("Licenses") }

    /// Tokens from `BUNDLE_MODELS="${BUNDLE_MODELS:-…}"`.
    static func defaultBundleTokens() throws -> [String] {
        let sh = try String(contentsOf: appRoot.appendingPathComponent("scripts/models_common.sh"), encoding: .utf8)
        let r = try #require(sh.range(of: #"BUNDLE_MODELS:-([^}]*)\}"#, options: .regularExpression))
        let inner = sh[r].dropFirst("BUNDLE_MODELS:-".count).dropLast()
        return inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Decision 2026-10-03: v2 (default, "English") + Ultra ("Noisy room / other languages").
    @Test func defaultBundleIsV2AndUltra() throws {
        let tokens = try Self.defaultBundleTokens()
        #expect(tokens == ["v2", "ultra"])
        #expect(tokens.compactMap(ASRModelVariant.init(rawValue:)) == [.parakeetV2, .parakeetUltra])
        #expect(ASRModelVariant(rawValue: tokens[0]) == .default)
        #expect(Set(ASRModelVariant.allCases) == Set([.parakeetV2, .parakeetUltra]))
    }

    /// Every bundled MODEL ships a NOTICE too (attribution + modifications); build_app.sh refuses otherwise.
    @Test func everyBundledModelHasANotice() throws {
        for tok in try Self.defaultBundleTokens() {
            let v = try #require(ASRModelVariant(rawValue: tok))
            let n = (try? String(contentsOf: Self.licenses.appendingPathComponent(v.folderName).appendingPathComponent("NOTICE"), encoding: .utf8)) ?? ""
            #expect(!n.isEmpty, "missing NOTICE for \(v.folderName)")
        }
        let sh = try String(contentsOf: Self.appRoot.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)
        #expect(sh.contains("/NOTICE (attribution required for every bundled model)"))
    }

    /// Attribution must name the exact revision used by the downloader, including the VAD.
    @Test(arguments: [("parakeet-tdt-0.6b-v2", "PARAKEET_V2"),
                      ("parakeet-ultra", "PARAKEET_ULTRA"), ("silero-vad", "SILERO_VAD")])
    func modelNoticeMatchesTheDownloadPin(_ folder: String, _ pinName: String) throws {
        let config = try String(contentsOf: Self.appRoot.appendingPathComponent("scripts/models_common.sh"), encoding: .utf8)
        let range = try #require(config.range(of: "WISPRLOCAL_REV_\(pinName)=\"[0-9a-f]{40}\"", options: .regularExpression))
        let revision = try #require(config[range].split(separator: "\"").dropFirst().first)
        let notice = try String(contentsOf: Self.licenses.appendingPathComponent("\(folder)/NOTICE"), encoding: .utf8)
        #expect(notice.contains(String(revision)), "\(folder) attribution does not match its download pin")
        #expect(notice.contains("FluidInference"))
    }

    @Test func everyBundledComponentHasALicence() throws {
        var folders = try Self.defaultBundleTokens().map { tok -> String in
            let v = try #require(ASRModelVariant(rawValue: tok), "unknown BUNDLE_MODELS token \(tok)")
            return v.folderName
        }
        folders += [ModelLocator.vadFolderName, "FluidAudio"]
        for f in folders {
            let lic = Self.licenses.appendingPathComponent(f).appendingPathComponent("LICENSE")
            let text = (try? String(contentsOf: lic, encoding: .utf8)) ?? ""
            #expect(!text.isEmpty, "missing licence for bundled \(f): \(lic.path)")
        }
        let ultra = try String(contentsOf: Self.licenses.appendingPathComponent("parakeet-ultra/LICENSE"), encoding: .utf8)
        #expect(ultra.contains("CC-BY-4.0"))
        let notice = try String(contentsOf: Self.licenses.appendingPathComponent("parakeet-ultra/NOTICE"), encoding: .utf8)
        for who in ["NVIDIA", "Moondream", "FluidInference"] { #expect(notice.contains(who), "attribution missing: \(who)") }
        let v2 = try String(contentsOf: Self.licenses.appendingPathComponent("parakeet-tdt-0.6b-v2/LICENSE"), encoding: .utf8)
        #expect(v2.contains("CC-BY-4.0"))
        let v2n = try String(contentsOf: Self.licenses.appendingPathComponent("parakeet-tdt-0.6b-v2/NOTICE"), encoding: .utf8)
        for who in ["NVIDIA", "nvidia/parakeet-tdt-0.6b-v2", "FluidInference", "CC-BY-4.0", "Modifications"] {
            #expect(v2n.contains(who), "v2 attribution missing: \(who)")
        }
        let fa = try String(contentsOf: Self.licenses.appendingPathComponent("FluidAudio/LICENSE"), encoding: .utf8)
        #expect(fa.contains("Apache License"))
    }

    @Test func catalogFindsMissingLicences() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let models = root.appendingPathComponent("Models"), lic = root.appendingPathComponent("Licenses")
        for m in ["parakeet-ultra", "silero-vad"] { try fm.createDirectory(at: models.appendingPathComponent(m), withIntermediateDirectories: true) }
        try fm.createDirectory(at: lic.appendingPathComponent("parakeet-ultra"), withIntermediateDirectories: true)
        try Data("CC-BY-4.0".utf8).write(to: lic.appendingPathComponent("parakeet-ultra/LICENSE"))
        #expect(LicenseCatalog.modelsMissingLicense(modelsDir: models, licensesDir: lic) == ["silero-vad"])
        #expect(LicenseCatalog.entries(in: lic).map(\.id) == ["parakeet-ultra"])
        #expect(LicenseCatalog.entries(in: Self.licenses).map(\.id).contains("FluidAudio"))
    }

    /// If a packaged app exists (scripts/build_app.sh), every bundled model folder has a licence.
    @Test func builtAppShipsLicencesForEveryBundledModel() {
        let res = Self.appRoot.appendingPathComponent("build.noindex/WisprLocal.app/Contents/Resources")
        guard FileManager.default.fileExists(atPath: res.appendingPathComponent("Models").path) else { return }
        #expect(LicenseCatalog.modelsMissingLicense(modelsDir: res.appendingPathComponent("Models"),
                                                    licensesDir: res.appendingPathComponent("Licenses")).isEmpty)
    }

    /// REL-3: both receiver packaging paths ship FluidAudio's licence + third-party notices.
    @Test(arguments: ["scripts/build_receiver.sh", "scripts/make_release.sh"])
    func receiverPackagingShipsFluidAudioLicences(_ script: String) throws {
        let sh = try String(contentsOf: Self.appRoot.appendingPathComponent(script), encoding: .utf8)
        #expect(sh.contains(#"rsync -a "$APP_DIR/Licenses/FluidAudio""#), "\(script)")
        #expect(FileManager.default.fileExists(atPath: Self.licenses.appendingPathComponent("FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md").path))
    }

    /// ASR/VAD needs no native text-normalization engine; catch accidental trait re-enablement.
    @Test func unusedNativeTextNormalizationIsExcluded() {
        #expect(!NemoTextNormalizer.isAvailable)
        #expect(!TextNormalizer.shared.isNativeAvailable)
        #expect(!FileManager.default.fileExists(atPath: Self.licenses.appendingPathComponent("FluidAudio/ThirdPartyLicenses/NemoTextProcessing-LICENSE.md").path))
    }
}
