import Foundation
import CryptoKit
import Security
import Network

enum APIKeyAccess: String, Codable, CaseIterable, Identifiable {
    case readOnly = "read-only", full = "full"
    var id: String { rawValue }
    var title: String { self == .full ? "Full access" : "Read-only" }
    func allows(_ method: String) -> Bool { self == .full || OperatingMode.observerMethods.contains(method) }
}

struct APIKeyRecord: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var digest: String
    var allowNetwork: Bool
    var allowedClients: String
    var access: APIKeyAccess
    init(id: UUID, name: String, createdAt: Date, digest: String, access: APIKeyAccess = .full, allowedClients: String = "", allowNetwork: Bool = false) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.digest = digest; self.access = access; self.allowedClients = allowedClients; self.allowNetwork = allowNetwork
    }
    private enum CodingKeys: String, CodingKey { case id,name,createdAt,digest,access,allowedClients,allowNetwork }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        id = try values.decode(UUID.self,forKey:.id); name = try values.decode(String.self,forKey:.name)
        createdAt = try values.decode(Date.self,forKey:.createdAt); digest = try values.decode(String.self,forKey:.digest)
        allowNetwork = try values.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? (decoder.userInfo[.legacyNetworkAccess] as? Bool ?? false)
        allowedClients = try values.decodeIfPresent(String.self, forKey: .allowedClients) ?? (decoder.userInfo[.legacyAllowedClients] as? String ?? "")
        _ = try IPNetwork.parseList(allowedClients)
        access = values.contains(.access) ? (APIKeyAccess(rawValue:try values.decode(String.self,forKey:.access)) ?? .readOnly) : .full
    }
}

private extension CodingUserInfoKey { static let legacyNetworkAccess = CodingUserInfoKey(rawValue: "legacyNetworkAccess")!; static let legacyAllowedClients = CodingUserInfoKey(rawValue: "legacyAllowedClients")! }

@MainActor final class APIKeyStore {
    let directory: URL
    private(set) var keys: [APIKeyRecord]
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blue Bubble Club"), legacyAllowedClients: String? = nil, legacyMode: OperatingMode? = nil, legacyNetworkAccess: Bool = false) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw ActionFailure.invalid }
        let file = directory.appendingPathComponent("keys.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let info = try FileManager.default.attributesOfItem(atPath: file.path)
            guard info[.type] as? FileAttributeType == .typeRegular else { throw ActionFailure.invalid }
            let decoder = JSONDecoder()
            decoder.userInfo[.legacyNetworkAccess] = legacyNetworkAccess
            decoder.userInfo[.legacyAllowedClients] = legacyAllowedClients ?? UserDefaults.standard.string(forKey: "allowedClientNetworks") ?? ""
            keys = try decoder.decode([APIKeyRecord].self, from: Data(contentsOf: file))
            if legacyMode == .readOnly {
                for index in keys.indices { keys[index].access = .readOnly }
            }
            // Persist inherited rules before per-token edits can diverge.
            try save(keys)
        } else { keys = [] }
    }
    static func digest(_ secret: String) -> String { SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined() }
    func create(name: String, access: APIKeyAccess = .full, allowedClients: String = "", allowNetwork: Bool = false) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw ActionFailure.invalid }
        _ = try IPNetwork.parseList(allowedClients)
        let secret = try Self.makeSecret()
        let record = APIKeyRecord(id: UUID(), name: name, createdAt: Date(), digest: Self.digest(secret), access:access, allowedClients:allowedClients, allowNetwork:allowNetwork)
        try save(keys + [record]); return secret
    }
    private static func makeSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ActionFailure.unavailable }
        return "bbc_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func rotate(_ id: UUID) throws -> String {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { throw ActionFailure.invalid }
        let secret = try Self.makeSecret()
        var next = keys
        next[index].digest = Self.digest(secret)
        try save(next)
        return secret
    }
    func revoke(_ id: UUID) throws { try save(keys.filter { $0.id != id }) }
    func allows(_ id: UUID, method: String) -> Bool { keys.first { $0.id == id }?.access.allows(method) == true }
    func updateAccess(_ id: UUID, access: APIKeyAccess) throws {
        guard let index = keys.firstIndex(where:{ $0.id == id }) else { throw ActionFailure.invalid }
        var next = keys; next[index].access = access; try save(next)
    }
    func update(_ id: UUID, access: APIKeyAccess, allowedClients: String, allowNetwork: Bool? = nil, name: String? = nil) throws {
        _ = try IPNetwork.parseList(allowedClients)
        guard let index = keys.firstIndex(where: { $0.id == id }) else { throw ActionFailure.invalid }
        var next = keys; next[index].access = access; next[index].allowedClients = allowedClients
        if let allowNetwork { next[index].allowNetwork = allowNetwork }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 100 else { throw ActionFailure.invalid }
            next[index].name = trimmed
        }
        try save(next)
    }
    func permits(_ id: UUID, endpoint: NWEndpoint?) -> Bool {
        guard let record = keys.first(where: { $0.id == id }),
              let rules = try? IPNetwork.parseList(record.allowedClients) else { return false }
        guard let endpoint else { return false }
        if !record.allowNetwork {
            guard let loopback = try? IPNetwork.parseList("127.0.0.0/8\n::1"),
                  IPNetwork.permits(endpoint, rules: loopback) else { return false }
        }
        if rules.isEmpty { return true }
        return IPNetwork.permits(endpoint, rules: rules)
    }
    func authenticate(_ secret: String) -> UUID? {
        guard secret.utf8.count <= 256 else { return nil }
        let digest = Array(Self.digest(secret).utf8)
        return keys.first { record in
            let expected = Array(record.digest.utf8)
            guard expected.count == digest.count else { return false }
            return zip(expected, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }?.id
    }
    private func save(_ value: [APIKeyRecord]) throws {
        let file = directory.appendingPathComponent("keys.json")
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        keys = value
    }
}
