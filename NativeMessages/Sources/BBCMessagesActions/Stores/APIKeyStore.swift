import Foundation
import CryptoKit
import Security

enum APIKeyAccess: String, Codable, CaseIterable, Identifiable {
    case readOnly = "read-only", full = "full"
    var id: String { rawValue }
    var title: String { self == .full ? "Full access" : "Read-only" }
    func allows(_ method: String) -> Bool { self == .full || OperatingMode.observerMethods.contains(method) }
}

struct APIKeyRecord: Codable, Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    let digest: String
    var access: APIKeyAccess
    init(id: UUID, name: String, createdAt: Date, digest: String, access: APIKeyAccess = .full) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.digest = digest; self.access = access
    }
    private enum CodingKeys: String, CodingKey { case id,name,createdAt,digest,access }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy:CodingKeys.self)
        id = try values.decode(UUID.self,forKey:.id); name = try values.decode(String.self,forKey:.name)
        createdAt = try values.decode(Date.self,forKey:.createdAt); digest = try values.decode(String.self,forKey:.digest)
        access = values.contains(.access) ? (APIKeyAccess(rawValue:try values.decode(String.self,forKey:.access)) ?? .readOnly) : .full
    }
}

@MainActor final class APIKeyStore {
    let directory: URL
    private(set) var keys: [APIKeyRecord]
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blue Bubble Club")) throws {
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
            keys = try JSONDecoder().decode([APIKeyRecord].self, from: Data(contentsOf: file))
        } else { keys = [] }
    }
    static func digest(_ secret: String) -> String { SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined() }
    func create(name: String, access: APIKeyAccess = .full) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw ActionFailure.invalid }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ActionFailure.unavailable }
        let secret = "bbc_" + Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = APIKeyRecord(id: UUID(), name: name, createdAt: Date(), digest: Self.digest(secret), access:access)
        try save(keys + [record]); return secret
    }
    func revoke(_ id: UUID) throws { try save(keys.filter { $0.id != id }) }
    func allows(_ id: UUID, method: String) -> Bool { keys.first { $0.id == id }?.access.allows(method) == true }
    func updateAccess(_ id: UUID, access: APIKeyAccess) throws {
        guard let index = keys.firstIndex(where:{ $0.id == id }) else { throw ActionFailure.invalid }
        var next = keys; next[index].access = access; try save(next)
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
