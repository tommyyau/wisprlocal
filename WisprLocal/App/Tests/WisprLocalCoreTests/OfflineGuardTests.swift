import Testing
import CryptoKit
import Foundation
@testable import WisprLocalCore

/// STRUCTURAL offline guarantee: no networking APIs or URLs anywhere in the app's sources,
/// except `WisprLocalCore/RemoteBridge/` and the `WisprLocalReceiver` target (tailnet-only,
/// enforced at runtime by `AddressPolicy.tailnetOnly`, tested below). Even there only
/// Network.framework is allowed: no URLSession / URLRequest / http(s) URLs / WebKit / processes.
/// Also forbids calling FluidAudio's downloaders from app code.
@Suite struct OfflineGuardTests {
    static let banned = ["URLSession", "URLRequest", "http://", "https://", "NWConnection",
                         "NWListener", "CFNetwork", "downloadAndLoad(", ".download(to", "ModelHub.loadModels",
                         "offlineMode = false", "import Network", "NSURLConnection", "WKWebView", "WebKit",
                         "Process(", "NSTask", "curl", "wget"]

    static var sourcesRoot: URL {
        // .../App/Tests/WisprLocalCoreTests/OfflineGuardTests.swift -> .../App/Sources
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    /// The ONLY source folders allowed to use Network.framework (relative to Sources/).
    static let networkExemptPrefixes = ["WisprLocalCore/RemoteBridge/", "WisprLocalReceiver/"]
    /// Banned even inside the exempt folders.
    static let bannedEverywhere = ["URLSession", "URLRequest", "http://", "https://", "CFNetwork",
                                   "NSURLConnection", "WKWebView", "WebKit", "Process(", "NSTask", "curl", "wget",
                                   "downloadAndLoad(", ".download(to", "ModelHub.loadModels", "offlineMode = false"]

    static func relativePath(_ url: URL) -> String {
        let root = sourcesRoot.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p
    }

    static func isNetworkExempt(_ relative: String) -> Bool {
        networkExemptPrefixes.contains { relative.hasPrefix($0) }
    }

    static func allSwiftFiles() -> [URL] {
        let e = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    static func swiftFiles() -> [URL] {
        allSwiftFiles().filter { !isNetworkExempt(relativePath($0)) }
    }

    static func violations(in files: [URL], banned: [String]) throws -> [String] {
        var v: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                for b in banned where line.contains(b) { v.append("\(relativePath(f)):\(i + 1): \(b)") }
            }
        }
        return v
    }

    @Test func scansAMeaningfulNumberOfFiles() {
        #expect(Self.swiftFiles().count >= 10)
    }

    @Test func noNetworkingInSources() throws {
        let violations = try Self.violations(in: Self.swiftFiles(), banned: Self.banned)
        #expect(violations.isEmpty, "Networking found in app sources: \(violations)")
    }

    @Test func exemptFoldersUseNetworkFrameworkOnly() throws {
        let exempt = Self.allSwiftFiles().filter { Self.isNetworkExempt(Self.relativePath($0)) }
        #expect(exempt.count >= 3, "RemoteBridge/ + receiver should be scanned")
        let violations = try Self.violations(in: exempt, banned: Self.bannedEverywhere)
        #expect(violations.isEmpty, "Non-Network.framework networking in exempt folders: \(violations)")
    }

    @Test func exemptionIsNarrow() {
        #expect(Self.isNetworkExempt("WisprLocalCore/RemoteBridge/BridgeClient.swift"))
        #expect(Self.isNetworkExempt("WisprLocalReceiver/main.swift"))
        #expect(!Self.isNetworkExempt("WisprLocalCore/Remote/RemoteInserter.swift"))
        #expect(!Self.isNetworkExempt("WisprLocal/RemoteBridge/Sneaky.swift"))
        #expect(!Self.isNetworkExempt("WisprLocal/RemoteSettingsView.swift"))
        #expect(!Self.isNetworkExempt("WisprLocalCore/Insertion/RemoteBridgeHelpers.swift"))
    }

    /// Runtime half of the exemption: RemoteBridge refuses every non-tailnet address.
    @Test func remoteBridgeRefusesNonTailnetAddresses() async {
        for host in ["127.0.0.1", "192.168.1.2", "10.1.2.3", "172.16.0.1", "8.8.8.8", "100.63.0.1", "100.128.0.1",
                     "example.com", "::1", "2001:4860:4860::8888"] {
            #expect(!AddressPolicy.tailnetOnly.permits(host), "\(host)")
            await #expect(throws: BridgeClientError.notTailnet, "\(host)") {
                try await BridgeClient().send("x", key: .init(size: .bits256), to: BridgeEndpoint(host: host, port: 47_655))
            }
        }
        #expect(AddressPolicy.tailnetOnly.permits("100.64.0.1"))
        #expect(AddressPolicy.tailnetOnly.permits("fd7a:115c:a1e0::1"))
    }

    @Test func requireOfflineThrowsWhenOff() {
        #expect(throws: OfflinePolicy.Violation.self) { try OfflinePolicy.requireOffline(isOffline: { false }) }
        #expect(throws: Never.self) { try OfflinePolicy.requireOffline(isOffline: { true }) }
    }
}
