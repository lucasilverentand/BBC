import Darwin
import XCTest
@testable import BBCMessagesActions

final class NativeActionTraceTests: XCTestCase {
    private let id = UUID().uuidString
    private func trace(_ method: String = "read", id: String? = nil) throws -> NativeActionTrace? {
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "trace_id": id ?? self.id])
        return NativeActionTrace(try JSONDecoder().decode(NativeRequest.self, from: data))
    }
    func testTraceCannotExposeRequestDataOrArbitraryErrors() throws {
        let trace = try XCTUnwrap(trace())
        let line = try XCTUnwrap(trace.line("owner@example.test", attempted: true, outcome: "uncertain",
            error: NSError(domain: "secret.example", code: -1743, userInfo: [NSLocalizedDescriptionKey: "/private/secret message"])))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(fields["stage"] as? String, "native_failure")
        XCTAssertEqual(fields["traceID"] as? String, id)
        XCTAssertEqual(fields["senderVisibility"] as? String, "unobserved")
        XCTAssertNil(fields["osStatus"])
        XCTAssertFalse(line.contains("secret")); XCTAssertFalse(line.contains("example.test"))
        XCTAssertEqual(Set(fields.keys), ["version", "source", "traceID", "spanID", "action", "stage", "attempted", "elapsedMS", "outcome", "senderVisibility"])
    }
    func testOnlySupportedActionsAndUUIDsAreTraceable() throws {
        XCTAssertNil(try trace("status")); XCTAssertNil(try trace("read", id: "owner@example.test"))
        for method in ["read", "read.status", "reply", "typing.start"] { XCTAssertNotNil(try trace(method)) }
    }
    @MainActor func testReadTraceDistinguishesUnhideFailureFromSubmissionWithoutChangingEffects() throws {
        let target = NativeMessageRead.Target(process: .init(pid: 42, uid: getuid()), messageGUID: id)
        var stages: [String] = [], sends = 0
        XCTAssertThrowsError(try NativeMessageRead.submit(target, effectiveUID: getuid(), currentProcess: target.process,
            unhide: { false }, observation: { stages.append($0) }, send: { sends += 1 }))
        XCTAssertEqual(stages, ["read_unhide_requested"]); XCTAssertEqual(sends, 0)
        stages = []
        XCTAssertThrowsError(try NativeMessageRead.submit(target, effectiveUID: getuid(), currentProcess: target.process,
            unhide: { true }, observation: { stages.append($0) }, send: { sends += 1; throw NSError(domain: NSOSStatusErrorDomain, code: -1712) }))
        XCTAssertEqual(stages, ["read_unhide_requested", "read_unhide_accepted", "read_submit"])
        XCTAssertEqual(sends, 1)
    }
    func testOnlyKnownOSStatusCodesCanEnterDiagnostics() throws {
        let trace = try XCTUnwrap(trace())
        for code in [-1743, -1712, -600, -609, -128, 987654321] {
            let line = try XCTUnwrap(trace.line("read_submit", attempted: true, error: NSError(domain: NSOSStatusErrorDomain, code: code)))
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(fields["osStatus"] as? Int, code == 987654321 ? nil : code)
        }
    }
    func testNativeSourceKeyMatchesTheBackendAndSatellite() throws {
        let data = try JSONSerialization.data(withJSONObject: ["method": "read", "trace_id": id,
            "params": ["chat_guid": "any;-;owner@example.test", "message_guid": "1848c83c-1962-4fb4-8e96-c7c489014195"]])
        let trace = try XCTUnwrap(NativeActionTrace(JSONDecoder().decode(NativeRequest.self, from: data)))
        XCTAssertEqual(trace.sourceKey, "c20a2bc6d0a7d44a59425db62213328f4020c908675bb01cf0a5d6bd908314b0")
    }
    func testCleanupReturnCannotClaimTheOwnedDraftWasCleared() throws {
        let value = try XCTUnwrap(trace("typing.start"))
        let line = try XCTUnwrap(value.line("typing_stopped", attempted: true))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(fields["stage"] as? String, "typing_cleanup_returned")
        XCTAssertNil(fields["outcome"])
    }
    func testSeparateInvocationsKeepTheOperationButHaveIndependentTimingSpans() throws {
        let first = try XCTUnwrap(trace()), second = try XCTUnwrap(trace())
        func fields(_ value: NativeActionTrace) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(value.line("received", attempted: false)).utf8)) as? [String: Any])
        }
        let a = try fields(first), b = try fields(second), again = try fields(first)
        XCTAssertEqual(a["traceID"] as? String, b["traceID"] as? String)
        XCTAssertNotEqual(a["spanID"] as? String, b["spanID"] as? String)
        XCTAssertEqual(a["spanID"] as? String, again["spanID"] as? String)
    }
}
