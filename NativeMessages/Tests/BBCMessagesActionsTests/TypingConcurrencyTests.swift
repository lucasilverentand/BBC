import Foundation
import XCTest
import SQLite3
import BBCClient
@testable import BBCMessagesActions

@MainActor final class TypingConcurrencyTests: XCTestCase {
    func testTypingWaitAllowsSendAndCleanupWaitsForItsLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("chat.db"), chat = "any;-;fixture@example.test", guid = UUID().uuidString
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) { XCTAssertEqual(sqlite3_exec(db,text,nil,nil,nil),SQLITE_OK) }
        sql("""
            CREATE TABLE message(guid TEXT,service TEXT,is_from_me INTEGER,is_read INTEGER,item_type INTEGER,text TEXT,is_sent INTEGER,error INTEGER);
            CREATE TABLE chat(guid TEXT,chat_identifier TEXT);
            CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
            INSERT INTO chat VALUES('\(chat)','fixture@example.test');
            INSERT INTO chat_handle_join VALUES(1,1);
            INSERT INTO message VALUES('\(guid)','iMessage',0,0,0,'fixture',1,0);
            INSERT INTO chat_message_join VALUES(1,1);
            """)
        let request = try JSONDecoder().decode(NativeRequest.self,from:JSONSerialization.data(withJSONObject:["method":"typing.start","params":["chat_guid":chat,"message_guid":guid,"read_guids":[guid],"typing_id":UUID().uuidString,"deadline":Date().addingTimeInterval(25).timeIntervalSince1970*1000]]))
        try await BridgeFixtureHarness.run { harness in
            let helper = try await FixtureHelper(harness:harness)
            let environment = NativeWorkerEnvironment(databaseURL:url,endpoint:harness.endpoint,lockDirectory:root,bridgeTimeout:3)
            var stop = false, waiting = false
            let task = Task { @MainActor in
                try JSONSerialization.data(withJSONObject:await NativeTypingSession.perform(request:request,environment:environment,stopped:{ stop },progress:{ stage,_ in if stage == "typing_wait" { waiting = true } }))
            }
            let start = try await helper.peer.asyncReceive()
            XCTAssertEqual(start.object?["request"]?.object?["method"]?.string,"typing.start")
            try await helper.reply(id:start.object!["id"]!.string!, .object(["ok":.bool(true)]))
            let deadline = Date().addingTimeInterval(3)
            while !waiting && Date() < deadline { try await Task.sleep(for:.milliseconds(5)) }
            XCTAssertTrue(waiting)
            // The idle lease must not reserve the lock used by plain sends and reads.
            var sendEnvironment = LocalRPC.Environment()
            sendEnvironment.databaseURL = url; sendEnvironment.supportDirectory = root
            var sends = 0
            let send = try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":"send","method":"send","params":["service":"imessage","to":"fixture@example.test","text":"reply"]])
            let result = await LocalRPC.respond(to:send,environment:sendEnvironment,actions:.init(ensureRunning:{ 1 },automationStatus:{ _ in 0 },execute:{ _ in
                sends += 1
                sql("INSERT INTO message VALUES('\(UUID().uuidString)','iMessage',1,1,0,'reply',1,0); INSERT INTO chat_message_join VALUES(1,last_insert_rowid());")
            }))
            XCTAssertEqual(result.object?["result"]?.object?["ok"]?.bool,true)
            XCTAssertEqual(sends,1)
            let readInput = try JSONSerialization.data(withJSONObject:["method":"read","params":["chat_guid":chat,"message_guid":guid,"read_guids":[guid]]])
            let readTask = Task { @MainActor in
                try JSONSerialization.data(withJSONObject:await BBCMessagesActions.perform(input:readInput,environment:environment))
            }
            let readPacket = try await helper.peer.asyncReceive()
            XCTAssertEqual(readPacket.object?["request"]?.object?["method"]?.string,"read")
            sql("UPDATE message SET is_read=1 WHERE guid='\(guid)'")
            try await helper.reply(id:readPacket.object!["id"]!.string!, .object(["ok":.bool(true)]))
            let readResult = try JSONSerialization.jsonObject(with:await readTask.value) as! [String:Any]
            XCTAssertEqual(readResult["ok"] as? Bool,true)
            // Cleanup queues before dispatch when another operation holds the lock.
            let held = try NativeOperationLock(name:"automation.lock",directory:root)
            stop = true
            try await Task.sleep(for:.milliseconds(150))
            held.release()
            let cleanup = try await helper.peer.asyncReceive()
            XCTAssertEqual(cleanup.object?["request"]?.object?["method"]?.string,"typing.stop")
            try await helper.reply(id:cleanup.object!["id"]!.string!, .object(["ok":.bool(true)]))
            let receipt = try JSONSerialization.jsonObject(with:await task.value) as! [String:Any]
            XCTAssertEqual(receipt["cleanup"] as? String,"confirmed")
            let released = try NativeOperationLock(name:"automation.lock",directory:root)
            released.release()
        }
    }
}
