import CryptoKit
import Foundation

/// RFC 4648 base32 (no padding). Decoding ignores case, spaces and dashes.
public enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ data: Data) -> String {
        var out = "", buffer: UInt32 = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte); bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)]); bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return out
    }

    public static func decode(_ s: String) -> Data? {
        var out = Data(), buffer: UInt32 = 0, bits = 0
        for ch in s.uppercased() where !ch.isWhitespace && ch != "-" && ch != "=" {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt32(v); bits += 5
            if bits >= 8 { out.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF)); bits -= 8 }
        }
        return out
    }
}

/// What the receiver shows and the sender pastes:
///   "WL1-" + base32( 0x01 ‖ nameCount ‖ (len ‖ utf8)* ‖ len ‖ host ‖ port(BE16) ‖ key(32) ‖ check(2) )
/// `check` = first 2 bytes of SHA-256 over everything before it (catches paste damage).
/// The code CONTAINS THE KEY: treat it like a password (copy it over the Screen Sharing session,
/// never post it anywhere). The fingerprint lets both screens confirm they hold the same key.
public struct PairingInfo: Sendable, Equatable {
    public var names: [String]   // display name first, then aliases (hostnames) for title matching
    public var host: String
    public var port: UInt16
    public var key: Data

    public init(names: [String], host: String, port: UInt16, key: Data) {
        self.names = names; self.host = host; self.port = port; self.key = key
    }

    public var fingerprint: String { PairingCode.fingerprint(key: key) }
}

public enum PairingCode {
    public static let prefix = "WL1-"
    public static let keyLength = 32

    public enum DecodeError: Error, LocalizedError, Equatable {
        case notAPairingCode, damaged, notTailnet
        public var errorDescription: String? {
            switch self {
            case .notAPairingCode: return "That is not a WisprLocal pairing code."
            case .damaged: return "The pairing code is incomplete or damaged — copy it again."
            case .notTailnet: return "The receiver's address is not a Tailscale address."
            }
        }
    }

    /// 8 hex chars of SHA-256(key), shown as "1A2B-3C4D" on both Macs.
    public static func fingerprint(key: Data) -> String {
        let hex = SHA256.hash(data: key).prefix(4).map { String(format: "%02X", $0) }.joined()
        return hex.prefix(4) + "-" + hex.suffix(4)
    }

    public static func encode(_ info: PairingInfo) -> String {
        var d = Data([1])
        let names = info.names.prefix(4).map { Data($0.utf8.prefix(63)) }
        d.append(UInt8(names.count))
        for n in names { d.append(UInt8(n.count)); d.append(n) }
        let host = Data(info.host.utf8.prefix(63))
        d.append(UInt8(host.count)); d.append(host)
        d.append(UInt8(info.port >> 8)); d.append(UInt8(info.port & 0xFF))
        d.append(info.key)
        d.append(contentsOf: SHA256.hash(data: d).prefix(2))
        // Groups of 4 for readability.
        let b32 = Array(Base32.encode(d))
        let groups = stride(from: 0, to: b32.count, by: 4).map { String(b32[$0..<min($0 + 4, b32.count)]) }
        return prefix + groups.joined(separator: "-")
    }

    public static func decode(_ code: String) throws -> PairingInfo {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.hasPrefix(prefix) else { throw DecodeError.notAPairingCode }
        guard let d = Base32.decode(String(trimmed.dropFirst(prefix.count))), d.count > 3 else { throw DecodeError.damaged }
        let bytes = [UInt8](d)
        let body = Array(bytes.dropLast(2))
        guard Array(SHA256.hash(data: Data(body)).prefix(2)) == Array(bytes.suffix(2)) else { throw DecodeError.damaged }
        var i = 0
        func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, i + n <= body.count else { throw DecodeError.damaged }
            defer { i += n }
            return Array(body[i..<i + n])
        }
        guard try take(1) == [1] else { throw DecodeError.damaged }
        let count = Int(try take(1)[0])
        var names: [String] = []
        for _ in 0..<count {
            let len = Int(try take(1)[0])
            guard let s = String(bytes: try take(len), encoding: .utf8) else { throw DecodeError.damaged }
            names.append(s)
        }
        let hlen = Int(try take(1)[0])
        guard let host = String(bytes: try take(hlen), encoding: .utf8) else { throw DecodeError.damaged }
        let p = try take(2)
        let key = Data(try take(keyLength))
        guard i == body.count else { throw DecodeError.damaged }
        guard TailnetAddress.isTailnet(host) else { throw DecodeError.notTailnet }
        return PairingInfo(names: names, host: host, port: UInt16(p[0]) << 8 | UInt16(p[1]), key: key)
    }
}
