import Foundation
import XCTest
import SQLite3
import BBCClient
@testable import BBCMessagesActions

final class EventsAndSearchTests: XCTestCase {
    private actor DeliveryGate {
        var pending: CheckedContinuation<Bool,Never>?
        var waiter: CheckedContinuation<Void,Never>?
        func hold() async -> Bool {
            await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
        }
        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { pending?.resume(returning:false); pending = nil }
    }
    private func fixture() throws -> (URL,OpaquePointer) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var connection: OpaquePointer?
        guard sqlite3_open(url.path,&connection) == SQLITE_OK, let connection else { throw ActionFailure.unavailable }
        XCTAssertEqual(sqlite3_exec(connection,"""
            CREATE TABLE message(guid TEXT,text TEXT,is_from_me INTEGER,date INTEGER,service TEXT,attributedBody BLOB,is_read INTEGER,is_sent INTEGER,is_delivered INTEGER,error INTEGER,date_edited INTEGER,date_retracted INTEGER);
            CREATE TABLE chat(guid TEXT);
            CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            INSERT INTO chat VALUES('any;-;fixture@example.test'),('any;-;other@example.test');
            """,nil,nil,nil),SQLITE_OK)
        return (url,connection)
    }
    private func insert(_ connection: OpaquePointer, guid: String = "11111111-1111-4111-8111-111111111111", text: String = "fixture", date: Int64 = 0, chat: Int = 1) {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection,"INSERT INTO message(guid,text,is_from_me,date,service,is_read,is_sent,is_delivered,error,date_edited,date_retracted) VALUES(?1,?2,0,?3,'iMessage',0,0,0,0,0,0)",-1,&statement,nil),SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_bind_text(statement,1,guid,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)),SQLITE_OK)
        XCTAssertEqual(sqlite3_bind_text(statement,2,text,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self)),SQLITE_OK)
        XCTAssertEqual(sqlite3_bind_int64(statement,3,date),SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE)
        XCTAssertEqual(sqlite3_exec(connection,"INSERT INTO chat_message_join VALUES(\(chat),last_insert_rowid())",nil,nil,nil),SQLITE_OK)
    }
    func testSearchCombinesLiteralUnicodeTextExactChatAndDates() throws {
        let (url,connection) = try fixture()
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url) }
        insert(connection,text:"Café 100%_complete",date:1_000_000_000)
        insert(connection,guid:"22222222-2222-4222-8222-222222222222",text:"CAFÉ 100%_complete",date:2_000_000_000,chat:2)
        insert(connection,guid:"33333333-3333-4333-8333-333333333333",text:"Cafe 100xxcomplete",date:3_000_000_000)
        let database = try MessagesDatabase(url:url)
        let result = try database.search(["text":.string("cafe 100%_"),"chat_guid":.string("any;-;fixture@example.test"),"from":.string("2001-01-01T00:00:01Z"),"to":.string("2001-01-01T00:00:03Z")])
        guard case .array(let messages) = result.object?["messages"] else { return XCTFail("Missing results") }
        XCTAssertEqual(messages.count,1)
        XCTAssertEqual(messages[0].object?["text"]?.string,"Café 100%_complete")
        XCTAssertThrowsError(try database.search([:]))
        XCTAssertThrowsError(try database.search(["from":.string("yesterday")]))
        XCTAssertThrowsError(try database.search(["text":.string("fixture"),"limit":.number(201)]))
    }
    func testSearchCompositeCursorKeepsSameRowInTwoConversations() throws {
        let (url,connection) = try fixture()
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url) }
        insert(connection)
        XCTAssertEqual(sqlite3_exec(connection,"INSERT INTO chat_message_join VALUES(2,1)",nil,nil,nil),SQLITE_OK)
        let database = try MessagesDatabase(url:url)
        let first = try database.search(["text":.string("fixture"),"limit":.number(1)])
        let second = try database.search(["text":.string("fixture"),"limit":.number(1),"before_rowid":first.object!["next_before_rowid"]!,"before_chat_guid":first.object!["next_before_chat_guid"]!])
        guard case .array(let a) = first.object?["messages"],case .array(let b) = second.object?["messages"] else { return XCTFail("Missing messages") }
        XCTAssertEqual(a.count,1); XCTAssertEqual(b.count,1)
        XCTAssertNotEqual(a[0].object?["chat_guid"],b[0].object?["chat_guid"])
    }
    func testSearchCanContinueAnEmptyBoundedScan() throws {
        let (url,connection) = try fixture()
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url) }
        insert(connection,text:"needle")
        XCTAssertEqual(sqlite3_exec(connection,"""
            WITH RECURSIVE numbers(x) AS (SELECT 2 UNION ALL SELECT x+1 FROM numbers WHERE x<502)
            INSERT INTO message(guid,text,is_from_me,date,service) SELECT printf('row-%d',x),'other',0,x,'iMessage' FROM numbers;
            INSERT INTO chat_message_join SELECT 1,ROWID FROM message WHERE ROWID>1;
            """,nil,nil,nil),SQLITE_OK)
        let database = try MessagesDatabase(url:url)
        let first = try database.search(["text":.string("needle")])
        XCTAssertEqual(first.object?["scanned"]?.numberValue,400)
        XCTAssertEqual(first.object?["messages"],.array([]))
        XCTAssertEqual(first.object?["more"]?.bool,true)
        let second = try database.search(["text":.string("needle"),"before_rowid":first.object!["next_before_rowid"]!,"before_chat_guid":first.object!["next_before_chat_guid"]!])
        guard case .array(let rows) = second.object?["messages"] else { return XCTFail("Missing results") }
        XCTAssertEqual(rows.count,1)
        XCTAssertEqual(rows.first?.object?["text"]?.string,"needle")
        XCTAssertEqual(second.object?["more"]?.bool,false)
    }
    @MainActor func testWebhookDetectsSameRowUpdatesAndRestartKeepsEventIDs() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let id = try XCTUnwrap(keys.authenticate(secret))
        var service: WebhookService? = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        _ = try await service!.handle(method:"webhooks.register",params:["url":.string("https://fixture.invalid/events")],keyID:id)
        let now = Date()
        insert(connection)
        await service!.tick(now:now)
        XCTAssertEqual(service!.state.deliveries.count,1)
        let first = service!.state.deliveries[0]
        XCTAssertEqual(try JSONDecoder().decode(BBCJSONValue.self,from:first.body).object?["type"]?.string,"message.received")
        XCTAssertEqual(sqlite3_exec(connection,"UPDATE message SET is_read=1,text='edited fixture',date_edited=10 WHERE ROWID=1",nil,nil,nil),SQLITE_OK)
        await service!.tick(now:now.addingTimeInterval(1))
        XCTAssertEqual(service!.state.deliveries.count,2)
        let ids = Set(service!.state.deliveries.map(\.id))
        service = nil
        let restarted = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        await restarted.tick(now:now.addingTimeInterval(3))
        XCTAssertEqual(Set(restarted.state.deliveries.map(\.id)),ids)
        XCTAssertEqual(restarted.state.deliveries.count,2)
        XCTAssertTrue(restarted.state.deliveries.contains { (try? JSONDecoder().decode(BBCJSONValue.self,from:$0.body).object?["type"]?.string) == "message.updated" })
    }
    @MainActor func testTwoSubscriptionsKeepSeparateDeliveryOutcomesAndRevocationPrunes() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        let keys = try APIKeyStore(directory:directory)
        let first = try XCTUnwrap(keys.authenticate(keys.create(name:"first")))
        let second = try XCTUnwrap(keys.authenticate(keys.create(name:"second")))
        let service = try WebhookService(keys:keys,databaseURL:url,deliver:{ $0.url?.host == "accepted.invalid" })
        let registration = try await service.handle(method:"webhooks.register",params:["url":.string("https://retry.invalid/events")],keyID:first)
        _ = try await service.handle(method:"webhooks.register",params:["url":.string("https://accepted.invalid/events")],keyID:second)
        insert(connection)
        await service.tick()
        XCTAssertEqual(service.state.deliveries.count,1)
        XCTAssertEqual(service.state.deliveries.first?.subscriptionID.uuidString,registration.object?["webhook_id"]?.string)
        try keys.revoke(first)
        await service.tick()
        XCTAssertTrue(service.state.deliveries.isEmpty)
        XCTAssertEqual(service.state.subscriptions.count,1)
    }
    @MainActor func testStoppedInflightDeliveryKeepsStoreOwnershipAndDispatchesNoMore() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let id = try XCTUnwrap(keys.authenticate(secret)), gate = DeliveryGate()
        let service = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in await gate.hold() })
        _ = try await service.handle(method:"webhooks.register",params:["url":.string("https://one.invalid/events")],keyID:id)
        _ = try await service.handle(method:"webhooks.register",params:["url":.string("https://two.invalid/events")],keyID:id)
        insert(connection)
        let work = Task { await service.tick() }
        await gate.waitUntilStarted()
        service.stop()
        XCTAssertThrowsError(try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false }))
        await gate.release(); await work.value
        XCTAssertEqual(service.state.deliveries.map(\.attempts),[1,0])
    }
    func testWebhookURLAndSignatureBindTheExactBodyAndTimestamp() {
        XCTAssertNil(WebhookService.validURL("http://remote.invalid/events"))
        XCTAssertNil(WebhookService.validURL("https://user:password@fixture.invalid/events"))
        XCTAssertNotNil(WebhookService.validURL("http://127.0.0.1:9000/events"))
        let secret = Data(repeating:7,count:32).base64EncodedString(), body = Data("{}".utf8)
        XCTAssertNotEqual(WebhookService.signature(secret:secret,timestamp:"1",body:body),WebhookService.signature(secret:secret,timestamp:"2",body:body))
        XCTAssertNotEqual(WebhookService.signature(secret:secret,timestamp:"1",body:body),WebhookService.signature(secret:secret,timestamp:"1",body:Data("{ }".utf8)))
    }
}
