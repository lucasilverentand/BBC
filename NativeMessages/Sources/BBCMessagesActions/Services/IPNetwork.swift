import Foundation
import Darwin
import Network

/// Numeric peer addresses only; DNS and forwarded headers are not trusted.
struct IPNetwork {
    let bytes: [UInt8]
    let prefix: Int
    init(_ text: String) throws {
        let parts = text.split(separator:"/",omittingEmptySubsequences:false)
        guard (1...2).contains(parts.count), let address = Self.address(String(parts[0])) else { throw ActionFailure.invalid }
        let bits = address.count * 8
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(parts[1]), (0...bits).contains(value) else { throw ActionFailure.invalid }
            prefix = value
        } else { prefix = bits }
        bytes = address
    }
    static func parseList(_ text: String) throws -> [Self] {
        let values = text.split(whereSeparator:{ $0.isWhitespace || $0 == "," })
        guard values.count <= 128, text.utf8.count <= 8192 else { throw ActionFailure.invalid }
        return try values.map { try Self(String($0)) }
    }
    func contains(_ address: [UInt8]) -> Bool {
        var address = address
        if bytes.count == 4, address.count == 16, Array(address.prefix(12)) == [0,0,0,0,0,0,0,0,0,0,255,255] { address = Array(address.suffix(4)) }
        guard bytes.count == address.count else { return false }
        let full = prefix / 8, remaining = prefix % 8
        guard bytes.prefix(full) == address.prefix(full) else { return false }
        return remaining == 0 || (bytes[full] ^ address[full]) & (UInt8.max << (8-remaining)) == 0
    }
    static func address(_ text: String) -> [UInt8]? {
        guard !text.isEmpty, !text.contains("%"), !text.utf8.contains(0), text.utf8.count <= 45 else { return nil }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET,text,&v4) == 1 { return withUnsafeBytes(of:&v4) { Array($0) } }
        if inet_pton(AF_INET6,text,&v6) == 1 { return withUnsafeBytes(of:&v6) { Array($0) } }
        return nil
    }
    static func permits(_ endpoint: NWEndpoint, rules: [Self]) -> Bool {
        guard !rules.isEmpty else { return true }
        guard case .hostPort(let host,_) = endpoint else { return false }
        let address: [UInt8]
        switch host {
        case .ipv4(let ip): address = Array(ip.rawValue)
        case .ipv6(let ip): address = Array(ip.rawValue)
        default: return false
        }
        return rules.contains { $0.contains(address) }
    }
}
