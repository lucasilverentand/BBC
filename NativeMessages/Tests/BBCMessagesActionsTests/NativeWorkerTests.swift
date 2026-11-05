import Foundation
import XCTest
import SQLite3
import BBCClient
@testable import BBCMessagesActions

/// Worker request-in/result-out tests against the shared fake bridge and a fixture SQLite database.
/// Every resource uses explicit temporary roots; nothing touches HOME, Messages or the host.
@MainActor
final class NativeWorkerTests: XCTestCase {
    private let chat = "any;-;owner@example.test"
    private let target = "11111111-1111-4111-8111-111111111111"
    private let sent = "22222222-2222-4222-8222-222222222222"
    private let other = "33333333-3333-4333-8333-333333333333"

    private struct Row {
        var guid: String, text: String? = nil, originator: String? = nil, chatID = 1, type = 0, associated: String? = nil
    }
    private enum Behavior {
        case ack(guid: String?, row: Row?), reject, absent, disconnect, idle
        var isAbsent: Bool { if case .absent = self { return true }; return false }
    }
    private struct Outcome { var receipt: [String: Any]; var packets: [[String: BBCJSONValue]] }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    private func insert(_ db: OpaquePointer?, _ row: Row) {
        func q(_ v: String?) -> String { v.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
        exec(db, """
            INSERT INTO message(guid,text,service,is_from_me,is_read,is_sent,error,associated_message_type,associated_message_guid,thread_originator_guid)
            VALUES(\(q(row.guid)),\(q(row.text)),'iMessage',1,1,1,0,\(row.type),\(q(row.associated)),\(q(row.originator)));
            INSERT INTO chat_message_join VALUES(\(row.chatID),(SELECT MAX(ROWID) FROM message));
            """)
    }

    private func scenario(_ method: String, extra: [String: Any] = [:], chatGUID: String? = nil, messageGUID: String? = nil,
                          lockHeld: Bool = false, anchorRoot: String? = nil, extraRows: [Row] = [], behavior: Behavior) async throws -> Outcome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bbc-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("chat.db"), locks = root.appendingPathComponent("locks", isDirectory: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
        exec(db, """
            CREATE TABLE message(guid TEXT,text TEXT,service TEXT,is_from_me INTEGER,is_read INTEGER,is_sent INTEGER DEFAULT 1,error INTEGER DEFAULT 0,
              associated_message_type INTEGER DEFAULT 0,associated_message_guid TEXT,thread_originator_guid TEXT,item_type INTEGER DEFAULT 0);
            CREATE TABLE chat(guid TEXT,chat_identifier TEXT);
            CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
            INSERT INTO chat VALUES('\(chat)','owner@example.test');
            INSERT INTO chat VALUES('any;-;second@example.test','second@example.test');
            INSERT INTO chat_handle_join VALUES(1,1);
            INSERT INTO chat_handle_join VALUES(2,2);
            INSERT INTO message(guid,service,is_from_me,is_read) VALUES('\(target)','iMessage',0,0);
            INSERT INTO chat_message_join VALUES(1,1);
            """)
        if let anchorRoot {
            let escaped = anchorRoot.replacingOccurrences(of:"'",with:"''")
            exec(db,"UPDATE message SET thread_originator_guid='\(escaped)' WHERE guid='\(target)'")
        }
        var params: [String: Any] = ["chat_guid": chatGUID ?? chat, "read_guids": [target]]
        if method == "reply" { params["reply_to"] = messageGUID ?? target } else { params["message_guid"] = messageGUID ?? target }
        for (key, value) in extra { params[key] = value }
        let input = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let held = lockHeld ? try NativeOperationLock(name: "automation.lock", directory: locks) : nil
        defer { held?.release() }
        var outcome = Outcome(receipt: [:], packets: [])

        try await BridgeFixtureHarness.run { harness in
            var helper: FixtureHelper? = behavior.isAbsent ? nil : try await FixtureHelper(harness: harness)
            let environment = NativeWorkerEnvironment(databaseURL: databaseURL, endpoint: harness.endpoint, lockDirectory: locks,
                                                      bridgeTimeout: 10, confirmationTimeout: 0.3, confirmationInterval: 10)
            let task = Task { @MainActor in try JSONSerialization.data(withJSONObject: await BBCMessagesActions.perform(input: input, environment: environment)) }
            switch behavior {
            case .absent, .idle: break
            case .ack, .reject, .disconnect:
                let packet = try await helper!.peer.asyncReceive()
                guard packet.object?["kind"]?.string == "command", let id = packet.object?["id"]?.string else { return XCTFail("not a command") }
                outcome.packets.append(packet.object?["request"]?.object ?? [:])
                switch behavior {
                case .ack(let guid, let row):
                    if let row { insert(db, row) }
                    extraRows.forEach { insert(db, $0) }
                    try await helper!.reply(id: id, .object(["ok": .bool(true)].merging(guid.map { ["guid": .string($0)] } ?? [:]) { $1 }))
                case .reject:
                    try await helper!.reply(id: id, .object(["ok": .bool(false), "uncertain": .bool(false), "failure_code": .string("native_rejected")]))
                default: helper!.peer.close()
                }
            }
            outcome.receipt = try JSONSerialization.jsonObject(with: try await task.value) as? [String: Any] ?? [:]
            if case .disconnect = behavior { return }   // the helper stream is gone; the single command was already consumed
            if helper == nil { helper = try await FixtureHelper(harness: harness) }
            // Barrier: the next ordered command must be the fresh call, so nothing else was forwarded or redispatched.
            try await helper!.expectNoStrayCommand(harness: harness)
        }
        return outcome
    }

    private func replyExtra(text: String = "hello") -> [String: Any] { ["text": text] }
    private func tapbackRow(guid: String? = nil) -> Row { Row(guid: guid ?? sent, type: 2000, associated: "p:0/" + target) }

    func testTapbackExactSentRowConfirms() async throws {
        let outcome = try await scenario("tapback", extra: ["reaction": "love"], behavior: .ack(guid: sent, row: tapbackRow()))
        XCTAssertEqual(outcome.receipt["ok"] as? Bool, true)
        XCTAssertEqual(outcome.receipt["guid"] as? String, sent)
        XCTAssertEqual(outcome.receipt["confirmation"] as? String, "local-database")
        XCTAssertEqual(outcome.packets.count, 1)
        XCTAssertEqual(outcome.packets[0]["associated_message_guid"]?.string, "p:0/" + target)
    }

    func testReplyExactRowConfirmsAndForwardsCanonicalMessageGUID() async throws {
        let outcome = try await scenario("reply", extra: replyExtra(), behavior: .ack(guid: sent, row: Row(guid: sent, text: "hello", originator: target)))
        XCTAssertEqual(outcome.receipt["ok"] as? Bool, true)
        XCTAssertEqual(outcome.receipt["guid"] as? String, sent)
        XCTAssertEqual(outcome.receipt["reply_to_guid"] as? String, target)
        XCTAssertEqual(outcome.receipt["thread_root_guid"] as? String, target)
        XCTAssertEqual(outcome.packets.count, 1)
        XCTAssertEqual(outcome.packets[0]["message_guid"]?.string, target, "raw packet must carry canonical message_guid, not only the reply_to alias")
        XCTAssertEqual(outcome.packets[0]["method"]?.string, "reply")
    }

    func testReplyConfirmationUsesExactAckEvenWithAnotherIdenticalThreadReply() async throws {
        let outcome = try await scenario("reply", extra: replyExtra(), extraRows:[Row(guid:other,text:"hello",originator:target)], behavior:.ack(guid:sent,row:Row(guid:sent,text:"hello",originator:target)))
        XCTAssertEqual(outcome.receipt["ok"] as? Bool,true)
        XCTAssertEqual(outcome.receipt["guid"] as? String,sent)
        XCTAssertEqual(outcome.packets.count,1)
    }
    func testReplyToChildKeepsRequestedAnchorSeparateFromThreadRoot() async throws {
        let outcome = try await scenario("reply", extra: replyExtra(), anchorRoot:"p:3/"+other, behavior:.ack(guid:sent,row:Row(guid:sent,text:"hello",originator:"p:3/"+other)))
        XCTAssertEqual(outcome.receipt["ok"] as? Bool,true)
        XCTAssertEqual(outcome.receipt["reply_to_guid"] as? String,target)
        XCTAssertEqual(outcome.receipt["thread_root_guid"] as? String,other)
        XCTAssertEqual(outcome.packets.first?["message_guid"]?.string,target)
        XCTAssertEqual(outcome.packets.count,1)
    }
    func testMalformedReplyRootRejectsBeforeNativeDispatch() async throws {
        let outcome = try await scenario("reply", extra: replyExtra(), anchorRoot:"malformed-root", behavior:.idle)
        XCTAssertEqual(outcome.receipt["ok"] as? Bool,false)
        XCTAssertEqual(outcome.receipt["uncertain"] as? Bool,false)
        XCTAssertEqual(outcome.receipt["failure_code"] as? String,"native_preparation")
        XCTAssertTrue(outcome.packets.isEmpty)
    }

    func testReplyWrongIdentityBodyRootOrChatIsUncertain() async throws {
        let cases: [(String, String?, Row)] = [
            ("wrong ack guid", other, Row(guid: sent, text: "hello", originator: target)),
            ("wrong body", sent, Row(guid: sent, text: "different", originator: target)),
            ("wrong root", sent, Row(guid: sent, text: "hello", originator: other)),
            ("wrong chat", sent, Row(guid: sent, text: "hello", originator: target, chatID: 2)),
        ]
        for (name, ack, row) in cases {
            let outcome = try await scenario("reply", extra: replyExtra(), behavior: .ack(guid: ack, row: row))
            XCTAssertEqual(outcome.receipt["ok"] as? Bool, false, name)
            XCTAssertEqual(outcome.receipt["uncertain"] as? Bool, true, name)
            XCTAssertEqual(outcome.packets.count, 1, name)
        }
    }

    func testTapbackWrongRowIsUncertain() async throws {
        let wrongTarget = Row(guid: sent, type: 2000, associated: "p:0/" + other)
        let wrongType = Row(guid: sent, type: 2001, associated: "p:0/" + target)
        for (name, ack, row) in [("no row", sent, nil), ("wrong target", sent, wrongTarget), ("wrong type", sent, wrongType), ("wrong ack", other, tapbackRow())] as [(String, String, Row?)] {
            let outcome = try await scenario("tapback", extra: ["reaction": "love"], behavior: .ack(guid: ack, row: row))
            XCTAssertEqual(outcome.receipt["uncertain"] as? Bool, true, name)
            XCTAssertEqual(outcome.packets.count, 1, name)
        }
    }

    func testNoRowAndInvalidAcknowledgementUUIDAreUncertain() async throws {
        for (name, ack) in [("no row", sent), ("invalid uuid", "not-a-uuid"), ("missing guid", nil)] as [(String, String?)] {
            let outcome = try await scenario("reply", extra: replyExtra(), behavior: .ack(guid: ack, row: nil))
            XCTAssertEqual(outcome.receipt["ok"] as? Bool, false, name)
            XCTAssertEqual(outcome.receipt["uncertain"] as? Bool, true, name)
            XCTAssertEqual(outcome.packets.count, 1, name)
        }
    }

    func testNativeNonDispatchedRejectionPassesThroughUnchanged() async throws {
        let outcome = try await scenario("tapback", extra: ["reaction": "love"], behavior: .reject)
        XCTAssertEqual(outcome.receipt["ok"] as? Bool, false)
        XCTAssertEqual(outcome.receipt["uncertain"] as? Bool, false)
        XCTAssertEqual(outcome.receipt["failure_code"] as? String, "native_rejected")
        XCTAssertEqual(outcome.packets.count, 1)
    }

    func testNoHelperIsNonDispatchedWithZeroCommands() async throws {
        let outcome = try await scenario("reply", extra: replyExtra(), behavior: .absent)
        XCTAssertEqual(outcome.receipt["ok"] as? Bool, false)
        XCTAssertEqual(outcome.receipt["uncertain"] as? Bool, false)
        XCTAssertEqual(outcome.receipt["failure_code"] as? String, "native_bridge_unavailable")
        XCTAssertTrue(outcome.packets.isEmpty)
    }

    func testHelperDisconnectAfterForwardingIsUncertain() async throws {
        let outcome = try await scenario("tapback", extra: ["reaction": "love"], behavior: .disconnect)
        XCTAssertEqual(outcome.receipt["ok"] as? Bool, false)
        XCTAssertEqual(outcome.receipt["uncertain"] as? Bool, true)
        XCTAssertEqual(outcome.packets.count, 1)
    }

    func testHeldLockSendsNothing() async throws {
        let outcome = try await scenario("reply", extra: replyExtra(), lockHeld: true, behavior: .idle)
        XCTAssertEqual(outcome.receipt["ok"] as? Bool, false)
        XCTAssertEqual(outcome.receipt["uncertain"] as? Bool, false)
        XCTAssertEqual(outcome.receipt["failure_code"] as? String, "native_preparation")
        XCTAssertTrue(outcome.packets.isEmpty)
    }

    func testUnknownChatOrMessageSendsNothing() async throws {
        for (method, chatGUID, message) in [("tapback", "any;-;nobody@example.test", nil), ("tapback", nil, other), ("reply", "any;-;nobody@example.test", nil), ("reply", nil, other)] as [(String, String?, String?)] {
            let extra: [String: Any] = method == "reply" ? replyExtra() : ["reaction": "love"]
            let outcome = try await scenario(method, extra: extra, chatGUID: chatGUID, messageGUID: message, behavior: .idle)
            XCTAssertEqual(outcome.receipt["ok"] as? Bool, false, method)
            XCTAssertEqual(outcome.receipt["uncertain"] as? Bool, false, method)
            XCTAssertEqual(outcome.receipt["failure_code"] as? String, "message_identity", method)
            XCTAssertTrue(outcome.packets.isEmpty, method)
        }
    }
}
