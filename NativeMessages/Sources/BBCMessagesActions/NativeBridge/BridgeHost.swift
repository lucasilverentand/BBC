import Foundation
import AppKit
import Darwin

struct BridgeReadiness: Sendable {
    enum SIP: String, Sendable { case enabled, disabled, unknown }
    let sip: SIP
    let libraryValidationDisabled: Bool
    var allowed: Bool { sip == .disabled && libraryValidationDisabled }
    static func parseSIP(_ output: String) -> SIP {
        switch output.trimmingCharacters(in:.whitespacesAndNewlines) {
        case "System Integrity Protection status: enabled.": .enabled
        case "System Integrity Protection status: disabled.": .disabled
        default: .unknown
        }
    }
    static func current() -> Self {
        func output(_ executable: String, _ arguments: [String]) -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            process.environment = ["LC_ALL":"C","PATH":"/usr/bin:/bin:/usr/sbin:/sbin"]
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0, data.count <= 4096 else { return "" }
            return String(data:data,encoding:.utf8) ?? ""
        }
        let sip = parseSIP(output("/usr/bin/csrutil",["status"]))
        let validation = output("/usr/bin/defaults",["read","/Library/Preferences/com.apple.security.libraryvalidation","DisableLibraryValidation"]).trimmingCharacters(in:.whitespacesAndNewlines)
        return .init(sip:sip,libraryValidationDisabled:validation == "1")
    }
}

/// An explicit operator-started session. No protection changes or launch retries.
@MainActor final class BridgeHost {
    private var broker: BridgeBroker?
    private var process: Process?
    private var sessionLock: NativeOperationLock?
    private(set) var starting = false
    func start() async throws {
        if let process, !process.isRunning { stop() }
        guard !starting, broker == nil else { throw ActionFailure.busy }
        starting = true; defer { starting = false }
        let readiness = await Task.detached { BridgeReadiness.current() }.value
        guard readiness.allowed else { throw ActionFailure.unavailable }
        guard let library = Bundle.main.privateFrameworksURL?.appendingPathComponent("BBCMessagesBridge.dylib"), FileManager.default.isReadableFile(atPath:library.path) else { throw ActionFailure.unavailable }
        let session = try NativeOperationLock(name:"native-session.lock")
        defer { if sessionLock !== session { session.release() } }
        let lockDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BBCMessagesActions",isDirectory:true)
        try FileManager.default.createDirectory(at:lockDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let lock = open(lockDirectory.appendingPathComponent("automation.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard lock >= 0 else { throw ActionFailure.unavailable }; defer { close(lock) }
        guard flock(lock,LOCK_EX|LOCK_NB) == 0 else { throw ActionFailure.busy }; defer { flock(lock,LOCK_UN) }
        // This button explicitly starts a new native session. Ask Messages to
        // quit gracefully; never force-kill it or alter its code/signature.
        if let running = NativeMessagesStartup.current(), let app = NSRunningApplication(processIdentifier:running.pid) {
            guard app.terminate() else { throw ActionFailure.busy }
            let deadline = Date().addingTimeInterval(5)
            while !app.isTerminated, Date() < deadline { try await Task.sleep(for:.milliseconds(100)) }
            guard app.isTerminated else { throw ActionFailure.busy }
        }
        let broker = try BridgeBroker(); self.broker = broker
        do {
            let (port,secret): (UInt16,String) = try await withCheckedThrowingContinuation { continuation in
                broker.start { port,secret in
                    if let port, let secret { continuation.resume(returning:(port,secret)) }
                    else { continuation.resume(throwing:ActionFailure.unavailable) }
                }
            }
            let messages = Process()
            messages.executableURL = URL(fileURLWithPath:"/System/Applications/Messages.app/Contents/MacOS/Messages")
            var environment = ["HOME":FileManager.default.homeDirectoryForCurrentUser.path,"USER":NSUserName(),"LOGNAME":NSUserName(),"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","TMPDIR":NSTemporaryDirectory()]
            environment["DYLD_INSERT_LIBRARIES"] = library.path
            environment["BBC_BRIDGE_PORT"] = String(port)
            environment["BBC_BRIDGE_SECRET"] = secret
            messages.environment = environment
            messages.standardOutput = FileHandle.nullDevice; messages.standardError = FileHandle.nullDevice
            messages.standardInput = FileHandle.nullDevice
            messages.terminationHandler = { [weak broker] _ in broker?.stop() }
            try messages.run(); process = messages
            let deadline = Date().addingTimeInterval(10)
            repeat {
                let status = await Task.detached { NativeBridgeClient.status() }.value
                if status.object?["ready"]?.bool == true { sessionLock = session; return }
                guard messages.isRunning else { throw ActionFailure.unavailable }
                try await Task.sleep(for:.milliseconds(200))
            } while Date() < deadline
            throw ActionFailure.unavailable
        } catch { stop(); throw error }
    }
    func stop() {
        broker?.stop(); broker = nil
        // Messages remains the operator's app. The embedded session stops its
        // own typing state on disconnect and cannot accept further commands.
        process = nil
        sessionLock?.release(); sessionLock = nil
    }
}
