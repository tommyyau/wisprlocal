import Foundation

/// One shipped licence folder (`Contents/Resources/Licenses/<id>/{LICENSE,NOTICE,…}`).
public struct LicenseEntry: Identifiable, Sendable, Equatable {
    public var id: String
    public var license: String
    public var notice: String?
    /// Extra files (e.g. FluidAudio's ThirdPartyLicenses/*), name → text.
    public var extras: [String: String]
}

/// Reads the licences shipped in the app bundle (About › Acknowledgements) and checks that every
/// bundled model has one (STRUCTURAL: `LicenseTests` + build_app.sh).
public enum LicenseCatalog {
    public static var bundledLicensesURL: URL? { Bundle.main.resourceURL?.appendingPathComponent("Licenses", isDirectory: true) }
    public static var bundledModelsURL: URL? { Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true) }

    static func subdirectories(_ dir: URL) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    public static func entries(in dir: URL) -> [LicenseEntry] {
        subdirectories(dir).compactMap { name in
            let d = dir.appendingPathComponent(name)
            guard let lic = try? String(contentsOf: d.appendingPathComponent("LICENSE"), encoding: .utf8) else { return nil }
            let notice = try? String(contentsOf: d.appendingPathComponent("NOTICE"), encoding: .utf8)
            var extras: [String: String] = [:]
            for sub in subdirectories(d) {
                let sd = d.appendingPathComponent(sub)
                for f in (try? FileManager.default.contentsOfDirectory(atPath: sd.path)) ?? [] {
                    extras["\(sub)/\(f)"] = try? String(contentsOf: sd.appendingPathComponent(f), encoding: .utf8)
                }
            }
            return LicenseEntry(id: name, license: lic, notice: notice, extras: extras)
        }
    }

    /// Model folders under `modelsDir` without a non-empty `licensesDir/<folder>/LICENSE`.
    public static func modelsMissingLicense(modelsDir: URL, licensesDir: URL) -> [String] {
        subdirectories(modelsDir).filter { name in
            let f = licensesDir.appendingPathComponent(name).appendingPathComponent("LICENSE")
            let size = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
            return size == 0
        }
    }
}
