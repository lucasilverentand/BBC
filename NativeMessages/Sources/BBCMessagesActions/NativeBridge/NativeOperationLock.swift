import Foundation
import Darwin

final class NativeOperationLock {
    private var fd: Int32 = -1
    init(name: String, directory override: URL? = nil) throws {
        guard ["media.lock","automation.lock","native-session.lock"].contains(name) else { throw ActionFailure.invalid }
        let directory = override ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BBCMessagesActions",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        fd = open(directory.appendingPathComponent(name).path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw ActionFailure.unavailable }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { close(fd); fd = -1; throw ActionFailure.busy }
    }
    func release() { if fd >= 0 { flock(fd,LOCK_UN); close(fd); fd = -1 } }
    deinit { release() }
}
