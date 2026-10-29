import AppKit
import CoreServices
import Darwin

/// Read opens an exact native message. It does not need the conversation-list
/// AX tree used by reactions and reply editing. The caller owns confirmation.
@MainActor enum NativeMessageRead {
    struct Target: Equatable {
        let process: NativeMessagesStartup.Process
        let messageGUID: String
    }

    static func messageURL(_ guid: String) throws -> URL {
        guard UUID(uuidString: guid) != nil else { throw ActionFailure.invalid }
        // Same message-guid deep link as the pinned Beeper adapter. No address,
        // compose body, overlay, generic URL launcher or unscoped window action.
        var components = URLComponents()
        components.scheme = "imessage"; components.path = "open"
        components.queryItems = [.init(name: "message-guid", value: guid)]
        guard let url = components.url else { throw ActionFailure.invalid }
        return url
    }

    private static func process(_ pid: pid_t) -> NativeMessagesStartup.Process? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == "com.apple.MobileSMS", !app.isTerminated,
              app.isFinishedLaunching else { return nil }
        return NativeMessagesStartup.process(app)
    }

    static func prepare(messageGUID: String, pid: pid_t) throws -> Target {
        try prepare(messageGUID: messageGUID, pid: pid, effectiveUID: geteuid(), lookup: process)
    }

    static func prepare(messageGUID: String, pid: pid_t, effectiveUID: UInt32,
                        lookup: (pid_t) -> NativeMessagesStartup.Process?) throws -> Target {
        _ = try messageURL(messageGUID)
        guard effectiveUID != 0 && effectiveUID == getuid(), pid > 0, let observed = lookup(pid),
              observed.pid == pid, observed.uid == effectiveUID else { throw ActionFailure.invalid }
        return .init(process: observed, messageGUID: messageGUID)
    }

    static func appleEvent(_ target: Target) throws -> NSAppleEventDescriptor {
        guard target.process.uid == getuid(), target.process.pid > 0 else { throw ActionFailure.invalid }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: target.process.pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: try messageURL(target.messageGUID).absoluteString),
                       forKeyword: AEKeyword(keyDirectObject))
        return event
    }

    static func submit(_ target: Target, observation: (String) -> Void = { _ in }) throws {
        guard let app = NSRunningApplication(processIdentifier: target.process.pid) else { throw ActionFailure.invalid }
        try submit(target, effectiveUID: geteuid(), currentProcess: process(target.process.pid), hidden: app.isHidden, unhide: { app.unhide() }, observation: observation) {
            try appleEvent(target).sendEvent(options: [.neverInteract, .noReply], timeout: 5)
        }
    }

    static func submit(_ target: Target, effectiveUID: UInt32, currentProcess: NativeMessagesStartup.Process?,
                       hidden: Bool = true, unhide: () -> Bool, observation: (String) -> Void = { _ in }, send: () throws -> Void) throws {
        guard effectiveUID != 0 && effectiveUID == getuid(), target.process.uid == getuid(), target.process.pid > 0,
              currentProcess == target.process else { throw ActionFailure.invalid }
        // Unhide only this verified process; do not activate another user or
        // create an Electron anchor. Give the GUID open an unhidden window.
        if hidden {
            observation("read_unhide_requested")
            guard unhide() else { throw ActionFailure.unavailable }
            observation("read_unhide_accepted")
        } else { observation("read_already_unhidden") }
        observation("read_submit")
        try send()
        observation("read_submitted")
    }

    static func perform(_ target: Target, recheck: () throws -> Bool,
                        progress: (String, Bool) -> Void,
                        submit: (Target) throws -> Void,
                        confirm: () async throws -> Void) async throws {
        progress("read_snapshot", false)
        try Task.checkCancellation()
        guard try recheck() else { return } // Desired state was already confirmed.
        try Task.checkCancellation()
        // Opening can itself mark the chat read. Every error from this point is
        // uncertain; missing confirmation must never cause another submission.
        progress("read_open", true)
        try submit(target)
        progress("read_confirmation", true)
        try await confirm()
    }
}
