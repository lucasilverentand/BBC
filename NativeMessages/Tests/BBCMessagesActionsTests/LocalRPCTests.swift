import Darwin
import SQLite3
import XCTest
import BBCClient
@testable import BBCMessagesActions

/// Synthetic SQLite and a fake script executor only. No AppleScript runs,
/// Messages is never started, and nothing outside the temporary root is read.
@MainActor final class LocalRPCTests: XCTestCase {
    private var root: URL!
    private var databaseURL: URL!
    private let recipient = "fixture@example.test"

    @MainActor override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalRPCTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        databaseURL = root.appendingPathComponent("chat.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE message(guid TEXT,service TEXT,is_from_me INTEGER,text TEXT,is_sent INTEGER,error INTEGER);
            CREATE TABLE chat(guid TEXT,chat_identifier TEXT);
            CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            INSERT INTO chat(ROWID,guid,chat_identifier) VALUES(1,'iMessage;-;fixture@example.test','fixture@example.test');
            """, nil, nil, nil), SQLITE_OK)
    }
    @MainActor override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func insert(guid: String, text: String, service: String = "iMessage", sent: Int = 1, error: Int = 0) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            INSERT INTO message(guid,service,is_from_me,text,is_sent,error) VALUES('\(guid)','\(service)',1,'\(text)',\(sent),\(error));
            INSERT INTO chat_message_join(chat_id,message_id) VALUES(1,last_insert_rowid());
            """, nil, nil, nil), SQLITE_OK)
    }
    private func environment(mode: OperatingMode = .full) -> LocalRPC.Environment {
        var e = LocalRPC.Environment()
        e.arguments = []; e.mode = mode; e.databaseURL = databaseURL
        e.supportDirectory = root.appendingPathComponent("support")
        e.mediaDirectory = root.appendingPathComponent("media")
        e.handoffDirectory = root.appendingPathComponent("handoff")
        e.confirmationTimeout = 0.3; e.pollInterval = 0.01
        return e
    }
    private final class Counters { var starts = 0, statuses = 0, scripts: [String] = [] }
    private func actions(_ c: Counters, startup: @escaping () async throws -> pid_t = { 99 }, status: OSStatus = noErr,
                         execute: @escaping (String) throws -> Void = { _ in }) -> LocalRPC.Actions {
        .init(ensureRunning: { c.starts += 1; return try await startup() },
              automationStatus: { _ in c.statuses += 1; return status },
              execute: { c.scripts.append($0); try execute($0) })
    }
    private func call(_ method: String, _ params: [String: Any], env: LocalRPC.Environment? = nil, actions: LocalRPC.Actions) async throws -> BBCJSONValue {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 7, "method": method, "params": params])
        return await LocalRPC.respond(to: body, environment: env ?? environment(), actions: actions)
    }
    private func disposition(_ v: BBCJSONValue) -> String? { v.object?["error"]?.object?["data"]?.object?["disposition"]?.string }
    private func methods(_ v: BBCJSONValue) -> [String] { { if case .array(let a)? = v.object?["result"]?.object?["methods"] { return a.compactMap(\.string) }; return [] }() }
    private func sendParams(_ over: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = ["service": "imessage", "to": recipient, "text": "hello"]
        for (k, v) in over { p[k] = v }
        return p
    }

    func testExactSingleRowConfirmsWithGUIDAfterOneScript() async throws {
        let c = Counters()
        let result = try await call("send", sendParams(), actions: actions(c, execute: { _ in try self.insert(guid: "G-1", text: "hello") }))
        XCTAssertEqual(result.object?["result"]?.object?["guid"]?.string, "G-1")
        XCTAssertEqual(result.object?["result"]?.object?["chat_guid"]?.string, "iMessage;-;fixture@example.test")
        XCTAssertEqual(c.scripts.count, 1); XCTAssertEqual(c.starts, 1)
    }
    func testPreExistingRowDoesNotConfirmAndNoRedispatch() async throws {
        try insert(guid: "OLD", text: "hello")
        let c = Counters()
        let result = try await call("send", sendParams(), actions: actions(c))
        XCTAssertEqual(disposition(result), "uncertain"); XCTAssertEqual(c.scripts.count, 1)
    }
    func testNoMatchingAndAmbiguousRowsAreUncertain() async throws {
        let none = Counters()
        var result = try await call("send", sendParams(), actions: actions(none, execute: { _ in try self.insert(guid: "X", text: "other") }))
        XCTAssertEqual(disposition(result), "uncertain"); XCTAssertEqual(none.scripts.count, 1)
        let many = Counters()
        result = try await call("send", sendParams(["text": "dup"]), actions: actions(many, execute: { _ in
            try self.insert(guid: "D1", text: "dup"); try self.insert(guid: "D2", text: "dup") }))
        XCTAssertEqual(disposition(result), "uncertain"); XCTAssertEqual(many.scripts.count, 1)
    }
    func testScriptThrowIsUncertainButNotStartedIsNotDispatched() async throws {
        let c = Counters()
        var result = try await call("send", sendParams(), actions: actions(c, execute: { _ in throw ActionFailure.uncertain }))
        XCTAssertEqual(disposition(result), "uncertain"); XCTAssertEqual(c.scripts.count, 1)
        result = try await call("send", sendParams(), actions: actions(Counters(), execute: { _ in throw LocalRPC.ScriptNotStarted() }))
        XCTAssertEqual(disposition(result), "not-dispatched")
    }
    func testInvalidSendInputsNeverReachStartupOrScript() async throws {
        let cases: [[String: Any]] = [
            ["to": "not a recipient"], ["to": "+1"], ["service": "sms"], ["service": NSNull()],
            ["allow_sms_fallback": true], ["text": ""], ["text": NSNull()],
            ["media_id": UUID().uuidString], ["text": "a\u{0}b"],
        ]
        for over in cases {
            let c = Counters()
            let result = try await call("send", sendParams(over), actions: actions(c))
            XCTAssertEqual(disposition(result), "not-dispatched", "\(over)")
            XCTAssertEqual(c.starts + c.scripts.count, 0, "\(over)")
        }
    }
    func testHeldLockDeniedPermissionAndStartupFailureAreNotDispatched() async throws {
        let env = environment()
        try FileManager.default.createDirectory(at: env.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(env.supportDirectory.appendingPathComponent("automation.lock").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        var c = Counters()
        var result = try await call("send", sendParams(), env: env, actions: actions(c))
        XCTAssertEqual(disposition(result), "not-dispatched"); XCTAssertEqual(c.starts + c.scripts.count, 0)
        flock(fd, LOCK_UN); close(fd)

        c = Counters()
        result = try await call("send", sendParams(), env: env, actions: actions(c, status: OSStatus(errAEEventNotPermitted)))
        XCTAssertEqual(disposition(result), "not-dispatched"); XCTAssertEqual(c.scripts.count, 0)

        c = Counters()
        result = try await call("send", sendParams(), env: env, actions: actions(c, startup: { throw ActionFailure.unavailable }))
        XCTAssertEqual(disposition(result), "not-dispatched"); XCTAssertEqual(c.scripts.count, 0)
    }
    func testReadOnlyModeRejectsSendBeforeAnythingRuns() async throws {
        let c = Counters()
        let result = try await call("send", sendParams(), env: environment(mode: .readOnly), actions: actions(c))
        XCTAssertEqual(disposition(result), "rejected"); XCTAssertEqual(c.starts + c.statuses + c.scripts.count, 0)
    }
    func testInvalidReadParametersAreNotDispatched() async throws {
        for params: [String: Any] in [["limit": 0], ["limit": 201], ["since_rowid": -1], ["since_rowid": 1.5], ["chat_guid": ""]] {
            let result = try await call("messages.after", params, actions: actions(Counters()))
            XCTAssertEqual(disposition(result), "not-dispatched", "\(params)")
        }
        let unknown = try await call("nope", [:], actions: actions(Counters()))
        XCTAssertEqual(disposition(unknown), "not-dispatched")
        let malformed = await LocalRPC.respond(to: Data("{".utf8), environment: environment(), actions: actions(Counters()))
        XCTAssertEqual(disposition(malformed), "not-dispatched")
    }
    func testStatusListsSendOnlyWhenAutomationGranted() async throws {
        var result = try await call("status", [:], actions: actions(Counters()))
        XCTAssertTrue(methods(result).contains("send"))
        result = try await call("status", [:], actions: actions(Counters(), status: OSStatus(errAEEventNotPermitted)))
        XCTAssertFalse(methods(result).contains("send"))
    }
}
