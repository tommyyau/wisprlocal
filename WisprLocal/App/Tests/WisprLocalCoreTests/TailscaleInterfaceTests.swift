import Testing
import Foundation
import Network
import CryptoKit
@testable import WisprLocalCore

/// SEC-3 (STRUCTURAL): "Tailscale only" is an interface check, not just an IP-range check.
@Suite struct TailscaleInterfaceTests {
    typealias E = TailscaleInterface.Entry

    /// The review's scenario: en0 has an ISP CGNAT address, Tailscale's utun has the real one.
    @Test func cgnatOnEn0IsNeverChosen() {
        let entries = [E(name: "en0", isPointToPoint: false, ip: "100.72.10.20"),   // CGNAT LAN/ISP
                       E(name: "utun4", ip: "100.101.102.103"),
                       E(name: "utun4", ip: "fd7a:115c:a1e0::1234")]
        #expect(TailscaleInterface.ipv4Address(from: entries) == .init(interface: "utun4", ip: "100.101.102.103"))
        #expect(!TailscaleInterface.addresses(from: entries).contains { $0.interface == "en0" })
    }

    @Test func cgnatOnlyOnEn0MeansNoTailscale() {
        let entries = [E(name: "en0", isPointToPoint: false, ip: "100.72.10.20"),
                       E(name: "en1", isPointToPoint: true, ip: "100.80.0.1"),     // p2p but not utun
                       E(name: "bridge0", ip: "100.90.0.1")]
        #expect(TailscaleInterface.ipv4Address(from: entries) == nil)
        #expect(TailscaleInterface.addresses(from: entries).isEmpty)
    }

    @Test func downOrNonPointToPointUtunIsIgnored() {
        #expect(TailscaleInterface.ipv4Address(from: [E(name: "utun3", isUp: false, ip: "100.64.0.9")]) == nil)
        #expect(TailscaleInterface.ipv4Address(from: [E(name: "utun3", isPointToPoint: false, ip: "100.64.0.9")]) == nil)
    }

    @Test func utunOutsideTailnetRangesIsIgnored() {
        let entries = [E(name: "utun0", ip: "10.8.0.2"), E(name: "utun1", ip: "fe80::1"),
                       E(name: "utun2", ip: "::ffff:100.64.0.1")]
        #expect(TailscaleInterface.addresses(from: entries).isEmpty)
    }

    /// Another VPN's utun with a 100.64/10 address loses to the utun that carries Tailscale's ULA.
    @Test func prefersTheInterfaceCarryingTheTailscaleULA() {
        let entries = [E(name: "utun2", ip: "100.66.0.5"),                    // other VPN, CGNAT space
                       E(name: "utun7", ip: "100.101.1.2"),
                       E(name: "utun7", ip: "fd7a:115c:a1e0:ab12::2")]
        let all = TailscaleInterface.addresses(from: entries)
        #expect(all.first == .init(interface: "utun7", ip: "100.101.1.2"))
        #expect(TailscaleInterface.ipv4Address(from: entries)?.interface == "utun7")
    }

    @Test func systemEnumerationOnlyReturnsUtun() {
        for a in TailscaleInterface.addresses() { #expect(a.interface.hasPrefix("utun"), "\(a)") }
    }

    // MARK: address literal hygiene

    @Test func rejectsMappedNamesAndNonCanonicalLiterals() {
        for bad in ["::ffff:100.64.0.1", "::ffff:6440:1", "[::ffff:100.64.0.1]", "0:0:0:0:0:ffff:6440:0001",
                    "macmini", "macmini.tail1234.ts.net", "100.64.0.1.nip.io", "100.064.0.1", "0100.64.0.1",
                    "100.64.00.1", " 100.64.0.1x", "100.64.0.1/32", "100.64.0.1:7878", "1681915905"] {
            #expect(!TailnetAddress.isTailnet(bad), "\(bad)")
            #expect(!AddressPolicy.tailnetOnly.permits(bad), "\(bad)")
        }
        #expect(TailnetAddress.isTailnet("100.64.0.1\n"))  // trailing newline from a paste is trimmed
    }

    @Test func pairingCodeRefusesNonLiteralHost() {
        let code = PairingCode.encode(PairingInfo(names: ["Studio"], host: "studio.tail1234.ts.net", port: 7878,
                                                  key: Data(repeating: 1, count: 32)))
        #expect(throws: (any Error).self) { try PairingCode.decode(code) }
    }

    // MARK: sender path requirement

    /// Documents the Network.framework semantics the design relies on: `.other` is the DEFAULT
    /// required interface type (i.e. "no requirement"), so it cannot be used to demand a utun.
    @Test func requiredInterfaceTypeOtherIsTheNoOpDefault() {
        #expect(NWParameters.tcp.requiredInterfaceType == .other)
    }

    @Test func senderParametersRefuseLoopbackAndThePublicClientRequiresATunnel() {
        let p = BridgeClient.parameters(requireTunnel: true)
        #expect(p.prohibitedInterfaceTypes == [.loopback])
        #expect(BridgeClient.parameters(requireTunnel: false).prohibitedInterfaceTypes?.isEmpty ?? true)
        #expect(BridgeClient().requireTunnel, "the public client must require a tunnel")
        #expect(!BridgeClient(policy: BridgeLoopbackTests.loopback).requireTunnel)
    }

    @Test func pathMustBeUtun() {
        #expect(BridgeClient.pathIsTunnel(interfaceNames: ["utun4"]))
        for bad in [[], ["en0"], ["en0", "utun4"], ["lo0"], ["ipsec0"], ["bridge100"]] {
            #expect(!BridgeClient.pathIsTunnel(interfaceNames: bad), "\(bad)")
        }
    }

    /// Real sockets: a tunnel-requiring client cannot reach a receiver over loopback (a non-utun
    /// path) — it fails before sending a byte and the server delivers nothing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WISPRLOCAL_NO_SOCKETS"] == nil))
    func tunnelRequiringClientRefusesLoopbackPath() async throws {
        let sink = BridgeLoopbackTests.Sink()
        let server = BridgeLoopbackTests().makeServer(sink)
        let port = try await server.start()
        defer { server.stop() }
        let client = BridgeClient(policy: BridgeLoopbackTests.loopback, requireTunnel: true)
        await #expect(throws: BridgeClientError.self) {
            _ = try await client.send("secret", key: BridgeLoopbackTests.key,
                                      to: BridgeEndpoint(host: "127.0.0.1", port: port), connectTimeout: .milliseconds(300))
        }
        // The client refused before connecting, so nothing can have reached the server.
        #expect(sink.texts.withLock { $0 }.isEmpty)
    }
}
