import Foundation
import Darwin

/// Read a selected Messages attachment through one open descriptor. A model
/// receives neither a filesystem path nor access to the attachment directory.
enum AttachmentFile {
    static let maximumBytes = 16 * 1024 * 1024

    static func read(_ filename: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     maximumBytes: Int = maximumBytes) throws -> Data {
        guard maximumBytes > 0, !filename.utf8.contains(0) else { throw ActionFailure.invalid }
        let root = home.appendingPathComponent("Library/Messages/Attachments", isDirectory: true).path
        let path = filename.hasPrefix("~/") ? home.path + String(filename.dropFirst()) : filename
        guard path.hasPrefix(root + "/") else { throw ActionFailure.invalid }
        let components = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw ActionFailure.invalid }
        // Resolve the trusted OS-provided home, then refuse symlinks in every
        // attachment component, including the final file. Never reopen by path.
        let rootFD = open(home.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw ActionFailure.unavailable }
        var directoryFD = rootFD
        defer { if directoryFD != rootFD { close(directoryFD) }; close(rootFD) }
        for component in ["Library", "Messages", "Attachments"] + components.dropLast().map(String.init) {
            let next = openat(directoryFD, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ActionFailure.invalid }
            if directoryFD != rootFD { close(directoryFD) }; directoryFD = next
        }
        let fd = openat(directoryFD, String(components.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ActionFailure.invalid }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maximumBytes else { throw ActionFailure.invalid }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, result.count + count <= maximumBytes else { throw ActionFailure.invalid }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              result.count == before.st_size else { throw ActionFailure.invalid }
        return result
    }
}
