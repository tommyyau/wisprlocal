import Darwin
import Foundation

/// STRUCTURAL: the bridge only ever talks to Tailscale addresses.
///   IPv4 100.64.0.0/10 (the IANA shared/CGNAT range Tailscale uses) and IPv6
///   fd7a:115c:a1e0::/48 (Tailscale's ULA). The IPv4 range is NOT Tailscale-specific (ISPs,
///   hotspots and other VPNs use it too), so an address check alone is never sufficient: the
///   receiver additionally binds only to a `utun*` point-to-point interface
///   (`TailscaleInterface`) and the sender requires a tunnel path (`BridgeClient`) — SEC-3.
/// Literal IPs only: host NAMES are refused (we cannot know where a name resolves), IPv4 must be
/// in canonical dotted-quad form, and IPv4-mapped IPv6 (`::ffff:100.64.0.1`) is refused.
public enum TailnetAddress {
    /// Strips `[...]` brackets and an IPv6 zone (`%utun3`).
    static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        return h
    }

    /// Canonical dotted-quad only ("100.64.0.1"; not "100.064.0.1" or other spellings).
    public static func ipv4Bytes(_ host: String) -> [UInt8]? {
        let h = normalize(host)
        var a = in_addr()
        guard inet_pton(AF_INET, h, &a) == 1 else { return nil }
        let b = withUnsafeBytes(of: a.s_addr) { Array($0) }  // network byte order
        guard b.map(String.init).joined(separator: ".") == h else { return nil }
        return b
    }

    public static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var a = in6_addr()
        guard inet_pton(AF_INET6, normalize(host), &a) == 1 else { return nil }
        return withUnsafeBytes(of: a) { Array($0) }
    }

    /// 100.64.0.0/10: first octet 100, top two bits of the second octet == 01.
    public static func isTailnetIPv4(_ b: [UInt8]) -> Bool {
        b.count == 4 && b[0] == 100 && (b[1] & 0xC0) == 0x40
    }

    /// fd7a:115c:a1e0::/48. (An IPv4-mapped address ::ffff:a.b.c.d never matches.)
    public static func isTailnetIPv6(_ b: [UInt8]) -> Bool {
        b.count == 16 && Array(b[0..<6]) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }

    /// ::ffff:0:0/96.
    public static func isIPv4Mapped(_ b: [UInt8]) -> Bool {
        b.count == 16 && b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff
    }

    public static func isTailnet(_ host: String) -> Bool {
        if let b = ipv4Bytes(host) { return isTailnetIPv4(b) }
        if let b = ipv6Bytes(host) { return !isIPv4Mapped(b) && isTailnetIPv6(b) }
        return false
    }
}

/// Which peer/bind addresses the bridge accepts. The ONLY public policy is `tailnetOnly`; the
/// memberwise init is internal so a loopback policy exists solely for the in-process tests.
public struct AddressPolicy: Sendable {
    let allows: @Sendable (String) -> Bool
    /// True only for `tailnetOnly` (the production policy): turns on the tunnel requirement.
    let isTailnetOnly: Bool
    init(allows: @escaping @Sendable (String) -> Bool) { self.allows = allows; self.isTailnetOnly = false }
    private init(tailnet: Void) { self.allows = { TailnetAddress.isTailnet($0) }; self.isTailnetOnly = true }

    public static let tailnetOnly = AddressPolicy(tailnet: ())

    public func permits(_ host: String) -> Bool { allows(TailnetAddress.normalize(host)) }
}

/// Finds this Mac's Tailscale address (the receiver binds ONLY to it).
///
/// SEC-3 (STRUCTURAL): an address qualifies only if it is on an UP, point-to-point `utun*`
/// interface (Tailscale's tunnel) AND inside the tailnet ranges. A CGNAT 100.64/10 address on
/// `en0` (cellular bridge, Starlink, hotspot) is never chosen. Among qualifying interfaces the
/// one that ALSO carries an fd7a:115c:a1e0::/48 address (Tailscale-specific) is preferred.
/// Residual: another VPN that puts a 100.64/10 address on a utun and no Tailscale ULA anywhere
/// would still qualify; the menu shows the interface name so the user can tell.
public enum TailscaleInterface {
    public struct Address: Sendable, Equatable {
        public let interface: String
        public let ip: String
        public init(interface: String, ip: String) { self.interface = interface; self.ip = ip }
    }

    /// One `getifaddrs` row (injected in tests).
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var isUp: Bool
        public var isPointToPoint: Bool
        public var ip: String
        public init(name: String, isUp: Bool = true, isPointToPoint: Bool = true, ip: String) {
            self.name = name; self.isUp = isUp; self.isPointToPoint = isPointToPoint; self.ip = ip
        }
    }

    static func isTunnel(_ e: Entry) -> Bool {
        e.isUp && e.isPointToPoint && e.name.hasPrefix("utun")
    }

    /// Pure selection: tailnet addresses on tunnel interfaces, interfaces carrying a Tailscale
    /// ULA first, IPv4 before IPv6 within an interface.
    public static func addresses(from entries: [Entry]) -> [Address] {
        let tunnel = entries.filter { isTunnel($0) && TailnetAddress.isTailnet($0.ip) }
        let ulaInterfaces = Set(tunnel.filter { TailnetAddress.ipv6Bytes($0.ip) != nil }.map(\.name))
        func rank(_ e: Entry) -> Int {
            (ulaInterfaces.contains(e.name) ? 0 : 2) + (TailnetAddress.ipv4Bytes(e.ip) != nil ? 0 : 1)
        }
        return tunnel.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { Address(interface: $0.element.name, ip: $0.element.ip) }
    }

    /// A NUL-terminated C buffer (e.g. from `inet_ntop`) as a String: truncated at the first NUL,
    /// decoded as UTF-8 (invalid bytes repaired, never read past the buffer).
    static func decodeCString(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The host's interfaces (all families we understand).
    public static func systemEntries() -> [Entry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Entry] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr else { continue }
            let flags = cur.pointee.ifa_flags
            let name = String(cString: cur.pointee.ifa_name)
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let ip: String
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                var a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { continue }
                ip = decodeCString(buf)
            case AF_INET6:
                var a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { continue }
                ip = decodeCString(buf)
            default: continue
            }
            out.append(Entry(name: name, isUp: (flags & UInt32(IFF_UP)) != 0,
                             isPointToPoint: (flags & UInt32(IFF_POINTOPOINT)) != 0, ip: ip))
        }
        return out
    }

    public static func addresses() -> [Address] { addresses(from: systemEntries()) }

    /// The tunnel's 100.x address, or nil if Tailscale is not running / not connected.
    public static func ipv4Address(from entries: [Entry]) -> Address? {
        addresses(from: entries).first { TailnetAddress.ipv4Bytes($0.ip) != nil }
    }

    public static func ipv4Address() -> Address? { ipv4Address(from: systemEntries()) }
}
