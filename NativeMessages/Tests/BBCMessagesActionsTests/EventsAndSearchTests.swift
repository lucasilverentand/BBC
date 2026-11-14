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
    @MainActor func testDatabaseRowRollbackLatchesAcrossRestartAndRequiresRegistration() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        insert(connection)
        XCTAssertEqual(sqlite3_exec(connection,"UPDATE message SET ROWID=20; UPDATE chat_message_join SET message_id=20",nil,nil,nil),SQLITE_OK)
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let keyID = try XCTUnwrap(keys.authenticate(secret))
        var service: WebhookService? = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        let registration = try await service!.handle(method:"webhooks.register",params:["url":.string("https://fixture.invalid/events")],keyID:keyID)
        let now = Date()
        insert(connection,guid:"22222222-2222-4222-8222-222222222222")
        await service!.tick(now:now)
        let pending = try XCTUnwrap(service!.state.deliveries.first?.id)
        XCTAssertEqual(service!.state.highWater,21)
        XCTAssertEqual(sqlite3_exec(connection,"DELETE FROM message; DELETE FROM chat_message_join",nil,nil,nil),SQLITE_OK)
        insert(connection,guid:"33333333-3333-4333-8333-333333333333")
        await service!.tick(now:now.addingTimeInterval(1))
        XCTAssertEqual(service!.observation,"database_changed")
        XCTAssertEqual(service!.state.deliveries.map(\.id),[pending])
        service = nil
        // Catching up to the old ROWID must not silently clear the source gate.
        XCTAssertEqual(sqlite3_exec(connection,"UPDATE message SET ROWID=30; UPDATE chat_message_join SET message_id=30",nil,nil,nil),SQLITE_OK)
        let restarted = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        await restarted.tick(now:now.addingTimeInterval(3))
        XCTAssertEqual(restarted.observation,"database_changed")
        XCTAssertEqual(restarted.state.deliveries.map(\.id),[pending])
        do {
            _ = try await restarted.handle(method:"webhooks.register",params:["url":.string("https://other.invalid/events")],keyID:keyID)
            XCTFail("Old registrations must be removed before rebasing")
        } catch {}
        _ = try await restarted.handle(method:"webhooks.remove",params:["webhook_id":registration.object!["webhook_id"]!],keyID:keyID)
        _ = try await restarted.handle(method:"webhooks.register",params:["url":.string("https://fixture.invalid/events")],keyID:keyID)
        insert(connection,guid:"44444444-4444-4444-8444-444444444444")
        await restarted.tick(now:now.addingTimeInterval(4))
        XCTAssertEqual(restarted.observation,"watching")
        XCTAssertEqual(restarted.state.deliveries.count,1)
        XCTAssertNotEqual(restarted.state.deliveries.first?.id,pending)
    }
    @MainActor func testDatabaseFileReplacementWithHigherRowsDoesNotReplayHistory() async throws {
        let (url,connection) = try fixture(), (replacement,replacementConnection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); sqlite3_close(replacementConnection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:replacement); try? FileManager.default.removeItem(at:directory) }
        insert(connection)
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let keyID = try XCTUnwrap(keys.authenticate(secret))
        var service: WebhookService? = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        _ = try await service!.handle(method:"webhooks.register",params:["url":.string("https://fixture.invalid/events")],keyID:keyID)
        await service!.tick()
        service = nil
        insert(replacementConnection,guid:"22222222-2222-4222-8222-222222222222")
        XCTAssertEqual(sqlite3_exec(replacementConnection,"UPDATE message SET ROWID=100; UPDATE chat_message_join SET message_id=100",nil,nil,nil),SQLITE_OK)
        try Data(contentsOf:replacement).write(to:url,options:.atomic)
        let restarted = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        await restarted.tick()
        XCTAssertEqual(restarted.observation,"database_changed")
        XCTAssertTrue(restarted.state.deliveries.isEmpty)
        XCTAssertEqual(restarted.state.highWater,1)
    }
    func testSourceIdentityIgnoresDeviceRenumbering() {
        XCTAssertTrue(WebhookService.sameSource("16777232:41714:1793909104:453085147","16777230:41714:1793909104:453085147"))
        XCTAssertFalse(WebhookService.sameSource("16777232:41714:1793909104:453085147","16777232:41715:1793909104:453085147"))
        XCTAssertFalse(WebhookService.sameSource("16777232:41714:1793909104:453085147","16777232:41714:1793909105:453085147"))
        XCTAssertFalse(WebhookService.sameSource("16777232:41714:1793909104:453085147","16777232:41714:1793909104:453085148"))
        XCTAssertFalse(WebhookService.sameSource("malformed","16777232:41714:1793909104:453085147"))
        let volume = "5F10CD38-3A2B-4A2C-8423-5D5E2AAB4B49", other = "0D1C9A5E-7B7A-4C3E-9E52-0B6F1C2D3E4F"
        XCTAssertTrue(WebhookService.sameSource("16777232:41714:1793909104:453085147:\(volume)","16777230:41714:1793909104:453085147:\(volume)"))
        XCTAssertFalse(WebhookService.sameSource("16777232:41714:1793909104:453085147:\(volume)","16777232:41714:1793909104:453085147:\(other)"))
        XCTAssertFalse(WebhookService.sameSource("16777232:41714:1793909104:453085147:\(volume)","16777232:41715:1793909104:453085147:\(volume)"))
        // Identities stored before the volume UUID was recorded keep matching.
        XCTAssertTrue(WebhookService.sameSource("16777232:41714:1793909104:453085147","16777230:41714:1793909104:453085147:\(volume)"))
        XCTAssertFalse(WebhookService.sameSource("16777232:41714:1793909104:453085147","16777230:41715:1793909104:453085147:\(volume)"))
        XCTAssertFalse(WebhookService.sameSource("16777232:41714:1793909104:453085147:\(volume):extra","16777232:41714:1793909104:453085147:\(volume)"))
    }
    /// Rewrites the stored identity as a reboot that renumbered the volume, or a replaced file, would leave it.
    private func rewriteStoredIdentity(in directory: URL, component: Int) throws {
        let file = directory.appendingPathComponent("webhooks.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        var parts = try XCTUnwrap(object["databaseIdentity"] as? String).split(separator:":").map(String.init)
        parts[component] = String(Int(parts[component])! + 1)
        object["databaseIdentity"] = parts.joined(separator:":")
        try JSONSerialization.data(withJSONObject:object).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    /// Replaces the stored identity's components after the device, inode and birth time.
    private func rewriteStoredVolume(in directory: URL, to volume: String?) throws {
        let file = directory.appendingPathComponent("webhooks.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        let parts = try XCTUnwrap(object["databaseIdentity"] as? String).split(separator:":").map(String.init)
        XCTAssertEqual(parts.count,5)
        object["databaseIdentity"] = (parts.prefix(4) + (volume.map { [$0] } ?? [])).joined(separator:":")
        try JSONSerialization.data(withJSONObject:object).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    /// Registers a subscription, ticks once and returns the stored identity.
    @MainActor private func registerAndTick(keys: APIKeyStore, keyID: UUID, url: URL) async throws -> String {
        let service = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        _ = try await service.handle(method:"webhooks.register",params:["url":.string("https://fixture.invalid/events")],keyID:keyID)
        await service.tick()
        return try XCTUnwrap(service.state.databaseIdentity)
    }
    @MainActor func testLegacyIdentityKeepsWatchingAndRecordsVolume() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        insert(connection)
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let keyID = try XCTUnwrap(keys.authenticate(secret))
        let identity = try await registerAndTick(keys:keys,keyID:keyID,url:url)
        XCTAssertEqual(identity.split(separator:":").count,5)
        try rewriteStoredVolume(in:directory,to:nil)
        let restarted = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        insert(connection,guid:"22222222-2222-4222-8222-222222222222")
        await restarted.tick()
        XCTAssertEqual(restarted.observation,"watching")
        XCTAssertEqual(restarted.state.deliveries.count,1)
        XCTAssertEqual(restarted.state.databaseIdentity,identity)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("webhooks.json"))) as? [String:Any])
        XCTAssertEqual(saved["databaseIdentity"] as? String,identity)
    }
    @MainActor func testRestoredCopyOnAnotherVolumeLatches() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        insert(connection)
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let keyID = try XCTUnwrap(keys.authenticate(secret))
        _ = try await registerAndTick(keys:keys,keyID:keyID,url:url)
        // Same inode and birth time on a different volume: a restored or migrated copy.
        try rewriteStoredVolume(in:directory,to:"0D1C9A5E-7B7A-4C3E-9E52-0B6F1C2D3E4F")
        let restarted = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        insert(connection,guid:"22222222-2222-4222-8222-222222222222")
        await restarted.tick()
        XCTAssertEqual(restarted.observation,"database_changed")
        XCTAssertTrue(restarted.state.deliveries.isEmpty)
    }
    @MainActor func testRebootDeviceRenumberingKeepsWebhooksWatching() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        insert(connection)
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let keyID = try XCTUnwrap(keys.authenticate(secret))
        var service: WebhookService? = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        _ = try await service!.handle(method:"webhooks.register",params:["url":.string("https://fixture.invalid/events")],keyID:keyID)
        await service!.tick()
        service = nil
        try rewriteStoredIdentity(in:directory,component:0)
        let restarted = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        insert(connection,guid:"22222222-2222-4222-8222-222222222222")
        await restarted.tick()
        XCTAssertEqual(restarted.observation,"watching")
        XCTAssertNil(restarted.state.databaseChanged)
        XCTAssertEqual(restarted.state.deliveries.count,1)
    }
    @MainActor func testChangedInodeStillLatches() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        insert(connection)
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let keyID = try XCTUnwrap(keys.authenticate(secret))
        var service: WebhookService? = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        _ = try await service!.handle(method:"webhooks.register",params:["url":.string("https://fixture.invalid/events")],keyID:keyID)
        await service!.tick()
        service = nil
        try rewriteStoredIdentity(in:directory,component:1)
        let restarted = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        insert(connection,guid:"22222222-2222-4222-8222-222222222222")
        await restarted.tick()
        XCTAssertEqual(restarted.observation,"database_changed")
        XCTAssertTrue(restarted.state.deliveries.isEmpty)
    }
    @MainActor func testUnchangedRevisitAdvancesInMemoryWithoutRewritingSnapshotFile() async throws {
        let (url,connection) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { sqlite3_close(connection); try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:directory) }
        XCTAssertEqual(sqlite3_exec(connection,"""
            WITH RECURSIVE numbers(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM numbers WHERE x<200)
            INSERT INTO message(guid,text,is_from_me,date,service) SELECT printf('%08d-1111-4111-8111-111111111111',x),'baseline',0,x,'iMessage' FROM numbers;
            INSERT INTO chat_message_join SELECT 1,ROWID FROM message;
            """,nil,nil,nil),SQLITE_OK)
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"fixture")
        let keyID = try XCTUnwrap(keys.authenticate(secret))
        let service = try WebhookService(keys:keys,databaseURL:url,deliver:{ _ in false })
        _ = try await service.handle(method:"webhooks.register",params:["url":.string("https://fixture.invalid/events")],keyID:keyID)
        await service.tick()
        XCTAssertEqual(service.state.snapshots.count,200)
        XCTAssertEqual(service.state.revisit,100)
        let file = directory.appendingPathComponent("webhooks.json"), saved = try Data(contentsOf:file)
        let modified = try FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate] as? Date
        await service.tick()
        XCTAssertEqual(service.state.revisit,200)
        XCTAssertEqual(try Data(contentsOf:file),saved)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate] as? Date,modified)
        await service.tick()
        XCTAssertEqual(service.state.revisit,0)
        XCTAssertEqual(try Data(contentsOf:file),saved)
        XCTAssertTrue(service.state.deliveries.isEmpty)
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
