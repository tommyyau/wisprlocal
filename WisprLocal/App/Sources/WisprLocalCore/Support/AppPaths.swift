import Foundation

public enum AppPaths {
    /// User-visible name (P2.1 rename).
    public static let displayName = "WisprLocal"
    public static let bundleID = "com.tommyyau.wisprlocal"
    /// Pre-rename Application Support folder (migrated from, never deleted).
    public static let legacyFolderName = "WisprLite"

    /// `~/Library/Application Support/WisprLocal` (created on demand).
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WisprLocal", isDirectory: true)
    }

    public static var defaultDictionaryURL: URL { appSupport.appendingPathComponent("dictionary.json") }
    public static var defaultHistoryDirectory: URL { appSupport }
    /// Default-on troubleshooting audio (`DebugRecordingStore`), local only.
    public static var debugRecordingsDirectory: URL { appSupport.appendingPathComponent("DebugRecordings", isDirectory: true) }

    public static func ensureDirectory(_ url: URL) throws {
        try ensurePrivateDirectory(url)
    }

    /// Owner-only permissions for everything that can hold dictated text, dictionary entries or
    /// audio (SEC-14): directories 0700, files 0600.
    public static let privateDirectoryMode: Int = 0o700
    public static let privateFileMode: Int = 0o600

    /// Creates `url` (and missing parents) with 0700. An existing directory is tightened to 0700
    /// only if it is one of ours (inside Application Support/WisprLocal); a user-chosen history
    /// folder that already exists is left as the user set it.
    public static func ensurePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if isOwnFolder(url) { try? fm.setAttributes([.posixPermissions: privateDirectoryMode], ofItemAtPath: url.path) }
            return
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: privateDirectoryMode])
    }

    static func isOwnFolder(_ url: URL) -> Bool {
        let own = appSupport.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p == own || p.hasPrefix(own + "/")
    }

    /// Atomic write, then 0600. (The temp file lives in a 0700 directory we created.)
    public static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        restrictToOwner(url)
    }

    /// chmod 0600 (best effort).
    public static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: privateFileMode], ofItemAtPath: url.path)
    }

    public static var legacyAppSupport: URL {
        appSupport.deletingLastPathComponent().appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    /// One-time migration WisprLite/ → WisprLocal/: copies `dictionary.json` and `history.jsonl`
    /// only if absent in the new folder. Never deletes or modifies the old folder; models are not
    /// copied (they're bundled). Returns the file names copied.
    @discardableResult
    public static func migrateLegacyData(from old: URL = legacyAppSupport, to new: URL = appSupport) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        var copied: [String] = []
        for name in ["dictionary.json", "history.jsonl"] {
            let src = old.appendingPathComponent(name), dst = new.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            do {
                try ensurePrivateDirectory(new)
                try fm.copyItem(at: src, to: dst)
                restrictToOwner(dst)
                copied.append(name)
            } catch {
                Log.error("migration of \(name) failed: \(error.localizedDescription)")
            }
        }
        return copied
    }
}
