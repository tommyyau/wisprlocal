import Testing
import Foundation

/// STRUCTURAL privacy guard: no personal data in tracked files. Mirrors the generic checks of
/// `scripts/privacy_scan.sh` (which the pre-commit hook runs on staged content):
///   - absolute home paths `/Users/<name>/` (only the placeholder `/Users/x/` is allowed)
///   - `*.local` hostnames and `*.ts.net` names (allowed: an "example" label, or an allowlist entry)
///   - Tailscale/CGNAT IPv4 100.64.0.0/10 (allowed: exact allowlist entries)
///   - e-mail addresses outside example.com/.org/.net, x.com and noreply.github.com
/// Synthetic test values live in `scripts/privacy_allowlist.txt` (exact tokens).
/// The PRIVATE denylist (owner-specific terms) is never in the repo: it is read from
/// `$WISPRLOCAL_PRIVATE_DENYLIST` or `~/.config/wisprlocal/private-denylist.txt` only if present.
/// Uses `git ls-files`; skips when not in a git work tree or git is unavailable.
@Suite struct PrivacyGuardTests {
    static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static var scriptsDir: URL { appRoot.appendingPathComponent("scripts") }

    // MARK: rules (pure)

    static func loadAllowlist() -> Set<String> {
        guard let text = try? String(contentsOf: scriptsDir.appendingPathComponent("privacy_allowlist.txt"), encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { raw in
            let t = (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            return t.isEmpty ? nil : t
        })
    }

    private static func rx(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: opts)
    }
    static let homePath = rx(#"/Users/([A-Za-z0-9._-]+)/"#)
    static let localHost = rx(#"((?:[A-Za-z0-9-]+\.)+local)(?![A-Za-z0-9-])"#, .caseInsensitive)
    static let tsNet = rx(#"((?:[A-Za-z0-9-]+\.)+ts\.net)(?![A-Za-z0-9-])"#, .caseInsensitive)
    static let cgnatIP = rx(#"(?<![0-9.])(100\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3})(?![0-9])"#)
    static let email = rx(#"([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)"#)

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [[String]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func isExampleHost(_ h: String) -> Bool {
        h.lowercased().split(separator: ".").contains("example")
    }

    /// Generic-rule violations in one line (empty = clean).
    static func violations(line: String, allow: Set<String>) -> [String] {
        var v: [String] = []
        for g in groups(homePath, line) where g[1] != "x" { v.append("home path /Users/\(g[1])/") }
        for g in groups(localHost, line) where !isExampleHost(g[1]) && !allow.contains(g[1].lowercased()) {
            v.append("local hostname \(g[1])")
        }
        for g in groups(tsNet, line) where !isExampleHost(g[1]) && !allow.contains(g[1].lowercased()) {
            v.append("tailnet name \(g[1])")
        }
        for g in groups(cgnatIP, line) {
            if let o2 = Int(g[2]), (64...127).contains(o2), !allow.contains(g[1]) { v.append("tailnet IPv4 \(g[1])") }
        }
        for g in groups(email, line) {
            let user = g[1], dom = g[2].lowercased()
            if dom.range(of: #"^[0-9]+x\."#, options: .regularExpression) != nil { continue }  // icon@2x.png
            let ok = dom.range(of: #"(^|\.)example\.(com|org|net)$"#, options: .regularExpression) != nil
                || dom == "x.com"
                || dom.range(of: #"(^|\.)noreply\.github\.com$"#, options: .regularExpression) != nil
                || allow.contains((user + "@" + dom).lowercased())
            if !ok { v.append("e-mail \(user)@\(dom)") }
        }
        return v
    }

    // MARK: repo access

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

    /// (repo root, tracked text files as (relative path, contents)); nil when not in a git checkout.
    static func trackedTextFiles() -> (String, [(String, String)])? {
        guard let (s1, top) = git(["rev-parse", "--show-toplevel"]), s1 == 0 else { return nil }
        let root = String(decoding: top, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (s2, list) = git(["-C", root, "ls-files", "-z"]), s2 == 0 else { return nil }
        let paths = list.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let files: [(String, String)] = paths.compactMap { p in
            guard let d = FileManager.default.contents(atPath: root + "/" + p), !d.contains(0),
                  let s = String(data: d, encoding: .utf8) else { return nil }  // binary / non-UTF-8
            return (p, s)
        }
        return (root, files)
    }

    static var privateDenylistURL: URL {
        if let p = ProcessInfo.processInfo.environment["WISPRLOCAL_PRIVATE_DENYLIST"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/wisprlocal/private-denylist.txt")
    }
    static var privateDenylistPresent: Bool { FileManager.default.isReadableFile(atPath: privateDenylistURL.path) }

    // MARK: tests

    @Test func trackedFilesHaveNoPersonalData() throws {
        guard let (_, files) = Self.trackedTextFiles() else { return }  // not a git checkout
        #expect(files.count > 50, "expected to scan the whole repo")
        let allow = Self.loadAllowlist()
        #expect(!allow.isEmpty, "scripts/privacy_allowlist.txt missing or empty")
        var bad: [String] = []
        for (path, text) in files {
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                for v in Self.violations(line: line, allow: allow) { bad.append("\(path):\(i + 1): \(v)") }
            }
        }
        #expect(bad.isEmpty, "personal data in tracked files (fix, or allowlist a synthetic value): \(bad)")
    }

    @Test(.enabled(if: PrivacyGuardTests.privateDenylistPresent, "no private denylist on this machine"))
    func trackedFilesHaveNoPrivateTerms() throws {
        guard let (_, files) = Self.trackedTextFiles() else { return }
        let terms = try String(contentsOf: Self.privateDenylistURL, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var bad: [String] = []
        for (path, text) in files {
            for (i, line) in text.lowercased().components(separatedBy: "\n").enumerated() where terms.contains(where: { line.contains($0) }) {
                bad.append("\(path):\(i + 1)")  // the term itself is not echoed
            }
        }
        #expect(bad.isEmpty, "private denylist term found at: \(bad)")
    }

    /// Positive and negative controls (strings are assembled so this file stays clean itself).
    @Test func rulesBite() {
        let allow: Set<String> = ["studio-mac.local", "100.90.1.2"]
        let at = "@"
        let mustFail = ["/Users/" + "alice/Documents", "ssh " + "box" + ".local", "office" + ".tail99" + ".ts.net",
                        "ip 100." + "100.1.2", "100." + "127.0.1", "mail jane" + at + "corp" + ".io",
                        "J.Doe" + at + "gmail" + ".com"]
        for s in mustFail { #expect(!Self.violations(line: s, allow: allow).isEmpty, "should flag: \(s)") }
        let mustPass = ["/Users/x/Applications/WisprLocal.app", "host.example.local", "studio-mac.local",
                        "MenuBarIcon" + at + "2x.png", "a" + at + "example.com", "b" + at + "example.org",
                        "a.b" + at + "x.com", "1+bot" + at + "users.noreply.github.com", "100.63.1.1", "100.128.0.1",
                        "100.90.1.2", "WisprLocal.app", "~/.local/share", "localhost", "devbox.example.ts.net"]
        for s in mustPass { #expect(Self.violations(line: s, allow: allow).isEmpty, "should pass: \(s)") }
    }

    /// The shell scanner (pre-commit hook) agrees: clean on the repo, fails on a planted value.
    @Test func shellScannerPassesRepoAndCatchesPlant() throws {
        guard Self.trackedTextFiles() != nil else { return }
        func run(_ args: [String]) throws -> Int32 {
            let p = Foundation.Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [Self.scriptsDir.appendingPathComponent("privacy_scan.sh").path] + args
            var env = ProcessInfo.processInfo.environment
            env["WISPRLOCAL_PRIVATE_DENYLIST"] = "/nonexistent/denylist"  // generic checks only
            p.environment = env
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            return p.terminationStatus
        }
        #expect(try run([]) == 0, "scripts/privacy_scan.sh fails on the tracked tree")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-plant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "clean text\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(try run(["--dir", dir.path]) == 0)
        try ("see /Users/" + "alice/notes\n").write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        #expect(try run(["--dir", dir.path]) == 1)
    }

    @Test func hookCallsScannerOnStagedContent() throws {
        let hook = try String(contentsOf: Self.scriptsDir.appendingPathComponent("hooks/pre-commit"), encoding: .utf8)
        #expect(hook.contains("privacy_scan.sh\" --staged"))
        #expect(FileManager.default.isExecutableFile(atPath: Self.scriptsDir.appendingPathComponent("hooks/pre-commit").path))
        #expect(FileManager.default.isExecutableFile(atPath: Self.scriptsDir.appendingPathComponent("privacy_scan.sh").path))
    }
}
