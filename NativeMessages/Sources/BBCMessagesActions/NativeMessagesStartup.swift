import AppKit
import CoreServices
import Darwin

/// Start only the fixed Messages app in BBC's own GUI session. Status reads
/// never launch it; an authorized, scope-checked UI action calls ensureRunning.
@MainActor enum NativeMessagesStartup {
    struct Process: Equatable { let pid: pid_t; let uid: UInt32 }
    static func process(_ app: NSRunningApplication) -> Process? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return nil }
        return Process(pid: app.processIdentifier, uid: info.pbi_uid)
    }
    static func current() -> Process? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS")
            .compactMap(process).first { $0.uid == getuid() }
    }
    static func automationStatus(pid: pid_t? = nil) -> OSStatus {
        guard geteuid() != 0 && geteuid() == getuid(), let pid = pid ?? current()?.pid else { return OSStatus(procNotFound) }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let descriptor = target.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false)
    }
    static func ensureRunning() async throws -> pid_t {
        try await ensureRunning(effectiveUID: geteuid(), lookup: current) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            let app = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Messages.app"), configuration: configuration)
            let deadline = Date().addingTimeInterval(5)
            while !app.isFinishedLaunching, !app.isTerminated, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard app.bundleIdentifier == "com.apple.MobileSMS", app.isFinishedLaunching, !app.isTerminated,
                  let owned = process(app) else { throw ActionFailure.unavailable }
            return owned
        }
    }
    static func ensureRunning(effectiveUID: UInt32, lookup: () -> Process?, launch: () async throws -> Process) async throws -> pid_t {
        guard effectiveUID != 0 && effectiveUID == getuid() else { throw ActionFailure.invalid }
        let app: Process
        if let existing = lookup() { app = existing } else { app = try await launch() }
        guard app.uid == effectiveUID, app.pid > 0 else { throw ActionFailure.invalid }
        return app.pid
    }
}
