import Foundation
import XCTest
@testable import BBCClient
import BBCSQLite

#if os(macOS)
final class TransportTests: XCTestCase {
    private func withHelper(_ body: String, run: (URL, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fixture")
        try Data(("#!/usr/bin/python3\nimport json, sys, os\nrequest = json.loads(sys.stdin.readline())\n" + body + "\n").utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try await run(helper, directory)
    }
    func testSendUsesMatchingJSONRPCReceipt() async throws {
        try await withHelper("assert request['method'] == 'send'\nprint(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{'guid':'fixture-sent'}}))") { helper, directory in
            let client = BBCClient(executable: helper, database: directory.appendingPathComponent("unused"))
            let result = try await client.request(.object(["method": .string("send"), "params": .object(["text": .string("fixture only")])]))
            XCTAssertEqual(result.object?["guid"]?.string, "fixture-sent")
        }
    }
    func testMismatchedReceiptIsUncertainAndNeverRetried() async throws {
        try await withHelper("open(os.path.join(os.path.dirname(__file__), 'calls'), 'a').write('1')\nprint(json.dumps({'jsonrpc':'2.0','id':'wrong','result':{}}))") { helper, directory in
            do { _ = try await BBCClient(executable: helper).request(.object(["method": .string("send")])) ; XCTFail("Expected uncertainty") }
            catch let error as BBCError { XCTAssertTrue(error.localizedDescription.contains("do not repeat")) }
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8), "1")
        }
    }
    func testProviderErrorsDoNotExposePrivateDiagnostics() async throws {
        try await withHelper("print(json.dumps({'jsonrpc':'2.0','id':request['id'],'error':{'message':'private body /secret/path','data':{}}}))") { helper, _ in
            do { _ = try await BBCClient(executable: helper).request(.object(["method": .string("send")])) ; XCTFail("Expected failure") }
            catch let error as BBCError { XCTAssertFalse(error.localizedDescription.contains("private body")); XCTAssertFalse(error.localizedDescription.contains("/secret")) }
        }
    }
    func testReplyRoutesToNativeHelperAndKeepsExactTarget() async throws {
        try await withHelper("assert request['method'] == 'reply'\nassert request['params']['reply_to'] == 'fixture-message'\nprint(json.dumps({'ok':True,'environment':os.getenv('BBC_FIXTURE')}))") { helper, directory in
            let client = BBCClient(executable: directory.appendingPathComponent("must-not-run"), nativeExecutable: helper, nativeEnvironment: ["BBC_FIXTURE":"scoped"])
            let result = try await client.request(.object(["method": .string("send"), "params": .object(["reply_to": .string("fixture-message")])]))
            XCTAssertEqual(result.object?["ok"]?.bool, true)
            XCTAssertEqual(result.object?["environment"]?.string, "scoped")
        }
    }
    func testNativeUncertaintyPassesThroughWithoutRetry() async throws {
        try await withHelper("open(os.path.join(os.path.dirname(__file__), 'calls'), 'a').write('1')\nprint(json.dumps({'ok':False,'uncertain':True,'failure_code':'read_open'}))") { helper, directory in
            let result = try await BBCClient(nativeExecutable: helper).request(.object(["method": .string("read")]))
            XCTAssertEqual(result.object?["uncertain"]?.bool, true)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8), "1")
        }
    }
    func testOversizedReceiptIsRejected() async throws {
        try await withHelper("print('x' * 2000001)") { helper, _ in
            do { _ = try await BBCClient(executable: helper).request(.object(["method": .string("send")])) ; XCTFail("Expected bound") }
            catch let error as BBCError { XCTAssertTrue(error.localizedDescription.contains("size bound")) }
        }
    }
    func testGUIDNormalizationPreservesThreadPartsAndRejectsInvalidIDs() {
        let guid = UUID().uuidString
        XCTAssertEqual(MessageGUID.normalize("p:3/" + guid), guid)
        XCTAssertNil(MessageGUID.normalize("p:-1/" + guid))
        XCTAssertNil(MessageGUID.normalize("latest"))
    }

    func testHistoryEnrichesThreadRootFromExactLocalMessageAndChat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("chat.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let chat = "iMessage;-;fixture"
        let own = UUID().uuidString, child = UUID().uuidString, threadRoot = UUID().uuidString, invalid = UUID().uuidString
        let otherChat = "iMessage;-;other"
        let sql = """
        CREATE TABLE message(ROWID INTEGER, guid TEXT, service TEXT, thread_originator_guid TEXT);
        CREATE TABLE chat(ROWID INTEGER, guid TEXT);
        CREATE TABLE chat_message_join(message_id INTEGER, chat_id INTEGER);
        INSERT INTO chat VALUES(1,'\(chat)'),(2,'\(otherChat)');
        INSERT INTO message VALUES(1,'\(own)','iMessage',NULL),(2,'p:3/\(child)','iMessage','bp:\(threadRoot)'),(3,'\(invalid)','iMessage','malformed-originator');
        INSERT INTO chat_message_join VALUES(1,1),(2,1),(3,1);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let helper = directory.appendingPathComponent("fixture")
        let page = "{'messages':[{'guid':'\(own)','chat_guid':'\(chat)'},{'guid':'p:3/\(child)','chat_guid':'\(chat)','reply_to_guid':'legacy-parent'},{'guid':'\(invalid)','chat_guid':'\(chat)'}]}"
        let body = "print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':" + page + "}))"
        try Data(("#!/usr/bin/python3\nimport json,sys\nrequest=json.loads(sys.stdin.readline())\n" + body + "\n").utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let result = try await BBCClient(executable: helper, database: dbURL).request(.object(["method": .string("messages.after")]))
        guard case .array(let rows) = result.object?["messages"] else { return XCTFail("Expected history rows") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].object?["guid"]?.string, own)
        XCTAssertEqual(rows[0].object?["chat_guid"]?.string, chat)
        XCTAssertEqual(rows[0].object?["thread_root_guid"]?.string, own)
        XCTAssertEqual(rows[0].object?["reply_to_guid"], .null)
        XCTAssertEqual(rows[1].object?["guid"]?.string, "p:3/\(child)")
        XCTAssertEqual(rows[1].object?["chat_guid"]?.string, chat)
        XCTAssertEqual(rows[1].object?["thread_root_guid"]?.string, threadRoot)
        XCTAssertEqual(rows[1].object?["reply_to_guid"]?.string, threadRoot)
        XCTAssertEqual(rows[2].object?["thread_root_guid"], .null)
        XCTAssertEqual(rows[2].object?["reply_to_guid"], .null)
    }
}

#if os(macOS)
extension TransportTests {
    func testTypingChildReceivesEOFOnCancellationAndNeverRunsWhenAlreadyCanceled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let marker = directory.appendingPathComponent("started"), child = BoundedMessagesProcess()
        let task = Task.detached {
            try await withTaskCancellationHandler {
                try await Task.detached { try child.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c", "IFS= read -r line; : > \"$1\"; cat >/dev/null; printf '{\"ok\":true}'", "typing-fixture",marker.path],input:Data("{}\n".utf8),timeoutSeconds:3,typingSession:true) }.value
            } onCancel: { child.cancelTyping() }
        }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath:marker.path) { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        task.cancel(); let result = try await task.value
        XCTAssertEqual(String(decoding:result,as:UTF8.self),"{\"ok\":true}")
        child.cancelTyping() // Idempotent close.
        let canceled = BoundedMessagesProcess(); canceled.cancelTyping()
        XCTAssertThrowsError(try canceled.run(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","exit 99"],input:Data("{}\n".utf8),typingSession:true))
    }
}
#endif

#endif
