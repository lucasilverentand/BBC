import Foundation
import CryptoKit
import Darwin

/// Public operator-staged weights. The BBC runtime user cannot replace the
/// manifest, model components or their parent directories. No runtime download.
enum LocalModels {
    static let revision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BBC_MODEL_DIRECTORY"] ?? "/Users/Shared/Blue Bubble Club Models.noindex/parakeet-v3-7dd20fe6", isDirectory: true)
    static let operatorUID = ProcessInfo.processInfo.environment["BBC_MODEL_OWNER_UID"].flatMap(UInt32.init) ?? 0
    struct Manifest: Decodable {
        let format: Int
        let repository: String
        let revision: String
        let files: [Entry]
    }
    struct Entry: Decodable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    static func manifest() throws -> Manifest {
        guard let url = Bundle.module.url(forResource: "ParakeetModels.lock", withExtension: "json") else { throw ActionFailure.unavailable }
        let result = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard result.format == 1, result.repository == "FluidInference/parakeet-tdt-0.6b-v3-coreml",
              result.revision == revision, result.files.count == 20 else { throw ActionFailure.unavailable }
        return result
    }
    private static func trusted(_ url: URL, directory: Bool) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0, [0, operatorUID].contains(info.st_uid), info.st_uid != geteuid(), info.st_mode & 0o022 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              access(url.path, directory ? R_OK | X_OK : R_OK) == 0 else { throw ActionFailure.unavailable }
        return info
    }
    static func verify(hashes: Bool) throws {
        let manifest = try manifest()
        _ = try trusted(directory.deletingLastPathComponent(), directory: true)
        _ = try trusted(directory, directory: true)
        var expected = Set<String>()
        for entry in manifest.files {
            let parts = entry.path.split(separator: "/")
            for end in 1...parts.count { expected.insert(parts.prefix(end).joined(separator: "/")) }
        }
        guard let contents = FileManager.default.enumerator(atPath: directory.path) else { throw ActionFailure.unavailable }
        for case let path as String in contents {
            guard expected.contains(path) else { throw ActionFailure.unavailable }
        }
        for entry in manifest.files {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  entry.bytes > 0, entry.sha256.count == 64 else { throw ActionFailure.unavailable }
            var url = directory
            for part in parts.dropLast() { url.appendPathComponent(String(part)); _ = try trusted(url, directory: true) }
            url.appendPathComponent(String(parts.last!))
            let info = try trusted(url, directory: false)
            guard info.st_size == entry.bytes else { throw ActionFailure.unavailable }
            if hashes {
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ActionFailure.unavailable }
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? file.close() }
                var hash = SHA256(), total: Int64 = 0
                while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
                    total += Int64(data.count); guard total <= entry.bytes else { throw ActionFailure.unavailable }
                    hash.update(data: data)
                }
                guard total == entry.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else { throw ActionFailure.unavailable }
            }
        }
    }
    static var ready: Bool { (try? verify(hashes: false)) != nil }
}
