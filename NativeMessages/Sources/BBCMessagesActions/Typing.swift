import Foundation
import AppKit
import ApplicationServices
import CoreServices
import Darwin
@preconcurrency import IMessage

/// The parent holds stdin open only during composition. EOF (including a parent
/// crash), deadline or failure always runs cleanup in this same UI controller.
@MainActor enum NativeTypingSession {
    static func run(initialize: (URL) throws -> PlatformAPI, decoded: (NativeRequest) -> Void, progress: (String, Bool) -> Void) async throws {
        progress("typing_input", false)
        var bytes = Data(), byte: UInt8 = 0
        while read(STDIN_FILENO, &byte, 1) == 1, byte != 10 {
            guard bytes.count < 65536 else { throw ActionFailure.invalid }; bytes.append(byte)
        }
        let request = try JSONDecoder().decode(NativeRequest.self, from: bytes)
        decoded(request)
        progress("typing_validation", false)
        guard request.method == "typing.start", AXIsProcessTrusted() else { throw ActionFailure.invalid }
        let params = try request.validated(), guid = params.message_guid!, deadline = params.deadline!
        progress("typing_snapshot", false)
        let database = try MessagesDatabase(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"))
        try database.verify(chat: params.chat_guid, message: guid)
        guard Set(try database.unread(chat: params.chat_guid)).isSubset(of: Set(params.read_guids!)) else { throw ActionFailure.invalid }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BBCMessagesActions",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        progress("typing_lock", false)
        let lock = open(directory.appendingPathComponent("automation.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard lock >= 0 else { throw ActionFailure.unavailable }; defer { close(lock) }
        guard flock(lock,LOCK_EX|LOCK_NB) == 0 else { throw ActionFailure.busy }; defer { flock(lock,LOCK_UN) }
        progress("typing_control", false)
        let flags = fcntl(STDIN_FILENO,F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO,F_SETFL,flags|O_NONBLOCK) == 0 else { throw ActionFailure.unavailable }
        func stopped() throws -> Bool {
            var value: UInt8 = 0
            let count = read(STDIN_FILENO,&value,1)
            if count == 0 { return true }
            guard count == -1, errno == EAGAIN || errno == EWOULDBLOCK else { throw ActionFailure.invalid }
            return Date().timeIntervalSince1970*1000 >= deadline
        }
        func proceed(_ phase: String) throws -> Bool {
            guard try !stopped() else {
                progress("typing_stopped_before_start", false)
                NativeIndicatorFailure.record(phase: "typing_stopped_before_start", attempted: false)
                let receipt = try JSONSerialization.data(withJSONObject: ["ok": true, "skipped": true, "phase": NativeIndicatorFailure.label(phase)])
                FileHandle.standardOutput.write(receipt + Data([10]))
                return false
            }
            return true
        }
        guard try proceed("typing_control") else { return }
        progress("typing_startup", false)
        let pid = try await NativeMessagesStartup.ensureRunning()
        progress("typing_permissions", false)
        guard NativeMessagesStartup.automationStatus(pid: pid) == noErr else { throw ActionFailure.unavailable }
        guard try proceed("typing_permissions") else { return }
        progress("typing_adapter", false)
        let api = try initialize(directory)
        progress("typing_scope", false)
        guard try proceed("typing_scope") else { return }
        guard Set(try database.unread(chat:params.chat_guid)).isSubset(of:Set(params.read_guids!)) else { throw ActionFailure.invalid }
        progress("typing_start", true)
        try await api.bbcTyping(threadID: params.chat_guid,messageID:guid,active:true)
        progress("typing_started", true)
        NativeIndicatorFailure.record(phase: "typing_started", attempted: true)
        progress("typing_wait", true)
        var waitError: Error?
        do { while try !stopped() { try await Task.sleep(for:.milliseconds(100)) } }
        catch { waitError = error }
        progress("typing_cleanup", true)
        try await api.bbcTyping(threadID:params.chat_guid,messageID:guid,active:false)
        if let waitError { throw waitError }
        progress("typing_stopped", true)
        NativeIndicatorFailure.record(phase: "typing_stopped", attempted: true)
        let receipt = try JSONSerialization.data(withJSONObject:["ok":true,"typing_id":params.typing_id!])
        FileHandle.standardOutput.write(receipt+Data([10]))
    }
}
