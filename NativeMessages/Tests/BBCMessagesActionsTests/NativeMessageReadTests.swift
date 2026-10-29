import Darwin
import AppKit
import CoreServices
import XCTest
@testable import BBCMessagesActions

@MainActor final class NativeMessageReadTests: XCTestCase {
    private let guid = "1848c83c-1962-4fb4-8e96-c7c489014195"
    private func target() throws -> NativeMessageRead.Target {
        try NativeMessageRead.prepare(messageGUID: guid, pid: 42, effectiveUID: getuid()) { .init(pid: $0, uid: getuid()) }
    }
    func testOnlyExactMessageGUIDCanBecomeANativeOpenURL() throws {
        let url = try NativeMessageRead.messageURL(guid)
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "imessage"); XCTAssertEqual(parts.path, "open"); XCTAssertNil(parts.host)
        XCTAssertEqual(parts.queryItems, [.init(name: "message-guid", value: guid)])
        for value in ["latest", "owner@example.test", guid + "&body=send", "p:0/" + guid, "", "../message"] {
            XCTAssertThrowsError(try NativeMessageRead.messageURL(value))
        }
    }
    func testProcessBindingRejectsAnotherUserAndChangedOrMissingPID() throws {
        for uid: UInt32 in [0, (getuid() + 1), (getuid() + 2)] {
            XCTAssertThrowsError(try NativeMessageRead.prepare(messageGUID: guid, pid: 42, effectiveUID: uid) { _ in
                XCTFail("Another user must not discover Messages"); return nil
            })
        }
        for observed: NativeMessagesStartup.Process? in [nil, .init(pid: 42, uid: (getuid() + 1)), .init(pid: 43, uid: getuid())] {
            XCTAssertThrowsError(try NativeMessageRead.prepare(messageGUID: guid, pid: 42, effectiveUID: getuid()) { _ in observed })
        }
        XCTAssertEqual(try target().process, .init(pid: 42, uid: getuid()))
        XCTAssertThrowsError(try NativeMessageRead.appleEvent(.init(process: .init(pid: 42, uid: (getuid() + 1)), messageGUID: guid)))
    }
    func testAppleEventTargetsTheVerifiedPIDAndContainsOnlyTheMessageURL() throws {
        let event = try NativeMessageRead.appleEvent(target())
        let address = try XCTUnwrap(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
        XCTAssertEqual(address.data, NSAppleEventDescriptor(processIdentifier: 42).data)
        XCTAssertEqual(address.descriptorType, NSAppleEventDescriptor(processIdentifier: 42).descriptorType)
        XCTAssertEqual(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, try NativeMessageRead.messageURL(guid).absoluteString)
        XCTAssertEqual(event.eventClass, AEEventClass(kInternetEventClass)); XCTAssertEqual(event.eventID, AEEventID(kAEGetURL))
    }
    func testReadNeedsNoConversationWindowAndSubmitsOnceBeforeConfirmation() async throws {
        var events: [String] = [], opens = 0
        let bound = try target()
        try await NativeMessageRead.perform(bound, recheck: { events.append("scope"); return true },
            progress: { events.append("\($0):\($1)") }, submit: {
                XCTAssertEqual($0, bound); opens += 1; events.append("open")
            }, confirm: { events.append("confirmed") })
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(events, ["read_snapshot:false", "scope", "read_open:true", "open", "read_confirmation:true", "confirmed"])
    }
    func testNewUnconsumedInputStopsBeforeOpening() async throws {
        var opens = 0, confirmed = false, phase = "", attempted = false
        do {
            try await NativeMessageRead.perform(target(), recheck: { throw ActionFailure.invalid },
                progress: { phase = $0; attempted = $1 }, submit: { _ in opens += 1 }, confirm: { confirmed = true })
            XCTFail("Scope changed")
        } catch {}
        XCTAssertEqual(opens, 0); XCTAssertFalse(confirmed); XCTAssertEqual(phase, "read_snapshot"); XCTAssertFalse(attempted)
    }
    func testVerifiedProcessIsUnhiddenBeforeItsSingleOpen() throws {
        let t = try target(); var events: [String] = []
        try NativeMessageRead.submit(t, effectiveUID: getuid(), currentProcess: t.process, unhide: { events.append("unhide"); return true }, send: { events.append("open") })
        XCTAssertEqual(events, ["unhide", "open"])
    }
    func testChangedProcessOrUserCannotUnhideOrOpen() throws {
        let t = try target()
        for (uid, process): (UInt32, NativeMessagesStartup.Process?) in [((getuid() + 1),t.process),(getuid(),nil),(getuid(),.init(pid:42,uid:(getuid() + 1))),(getuid(),.init(pid:43,uid:getuid()))] {
            XCTAssertThrowsError(try NativeMessageRead.submit(t, effectiveUID: uid, currentProcess: process, unhide: { XCTFail("Wrong process"); return true }, send: { XCTFail("Wrong process") }))
        }
    }
    func testFailedUnhideCannotSubmitAnotherNativeOpen() throws {
        let t = try target(); var calls = 0
        XCTAssertThrowsError(try NativeMessageRead.submit(t, effectiveUID: getuid(), currentProcess: t.process, unhide: { calls += 1; return false }, send: { XCTFail("Unhide was not accepted") }))
        XCTAssertEqual(calls, 1)
    }
    func testAnAlreadyUnhiddenProcessNeedsNoUnhideRequestBeforeItsSingleOpen() throws {
        let t = try target(); var stages: [String] = [], opens = 0
        try NativeMessageRead.submit(t, effectiveUID: getuid(), currentProcess: t.process, hidden: false,
            unhide: { XCTFail("Already unhidden; do not gate Read on a redundant request"); return false },
            observation: { stages.append($0) }, send: { opens += 1 })
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(stages, ["read_already_unhidden", "read_submit", "read_submitted"])
        XCTAssertThrowsError(try NativeMessageRead.submit(t, effectiveUID: (getuid() + 1), currentProcess: t.process, hidden: false,
            unhide: { XCTFail("Wrong user"); return true }, send: { XCTFail("Wrong user") }))
    }
    func testAlreadyReadStateDoesNotOpenOrRepeatConfirmation() async throws {
        try await NativeMessageRead.perform(target(), recheck: { false }, progress: { _, attempted in XCTAssertFalse(attempted) },
            submit: { _ in XCTFail("Already read") }, confirm: { XCTFail("Already confirmed by recheck") })
    }
    func testSubmissionFailureIsUncertainAndNeverRetried() async throws {
        var opens = 0, phase = "", attempted = false
        do {
            try await NativeMessageRead.perform(target(), recheck: { true }, progress: { phase = $0; attempted = $1 },
                submit: { _ in opens += 1; throw ActionFailure.unavailable }, confirm: { XCTFail("No confirmed submission") })
            XCTFail("Submission failed")
        } catch {
            let disposition = NativeReadFailureDisposition.resolve(error, phase: phase, attempted: attempted)
            XCTAssertEqual(disposition.phase, "read_open"); XCTAssertTrue(disposition.attempted)
        }
        XCTAssertEqual(opens, 1)
    }
    func testMissingConfirmationKeepsUncertaintyWithoutAnotherOpen() async throws {
        var opens = 0, phase = "", attempted = false
        do {
            try await NativeMessageRead.perform(target(), recheck: { true }, progress: { phase = $0; attempted = $1 },
                submit: { _ in opens += 1 }, confirm: { throw ActionFailure.uncertain })
            XCTFail("No confirmation")
        } catch {
            let disposition = NativeReadFailureDisposition.resolve(error, phase: phase, attempted: attempted)
            XCTAssertEqual(disposition.phase, "read_confirmation"); XCTAssertTrue(disposition.attempted)
        }
        XCTAssertEqual(opens, 1)
    }
    func testCancellationDuringScopeRecheckCannotOpenAMessage() async throws {
        let bound = try target()
        let run = Task { @MainActor in
            do {
                try await NativeMessageRead.perform(bound, recheck: { withUnsafeCurrentTask { $0?.cancel() }; return true },
                    progress: { _, attempted in XCTAssertFalse(attempted) }, submit: { _ in XCTFail("Cancelled") }, confirm: { XCTFail("Cancelled") })
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await run.value
    }
}
