import Foundation
import XCTest
import BBCClient
import SQLite3
@testable import BBCMessagesActions

@MainActor final class ExpandedAPITests: XCTestCase {
    func testNewSDKRoutesPreservePayloadAndMutationReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let keys = try APIKeyStore(directory:directory), key = try keys.create(name:"Routing fixture")
        var calls: [String:Int] = [:]
        let router = APIRouter(keys:keys) { request in
            let method = try XCTUnwrap(request.object?["method"]?.string)
            calls[method,default:0] += 1
            return .object(["method":.string(method),"params":request.object?["params"] ?? .null])
        }
        let port = UInt16.random(in:20000...45000)
        let server = try LocalAPIServer(host:"127.0.0.1",port:port,router:router)
        defer { server.stop() }
        let ready = await withCheckedContinuation { continuation in
            let once = ExpandedReadyOnce(continuation); server.start { once.finish($0) }
        }
        XCTAssertTrue(ready)
        let client = BBCHTTPClient(baseURL:URL(string:"http://127.0.0.1:\(port)")!,apiKey:key)
        let params: BBCJSONValue = .object(["fixture":.string("exact original fields")])
        for method in ["groups.create","groups.add","groups.remove","groups.name","groups.photo","groups.leave","messages.edit","messages.unsend","messages.multipart"] {
            let payload: BBCJSONValue = .object(["method":.string(method),"params":params])
            do { _ = try await client.request(payload); XCTFail("Mutation needs an operation UUID") }
            catch { XCTAssertNil(calls[method]) }
            let id = UUID()
            let result = try await client.request(payload,operationID:id)
            XCTAssertEqual(result.object?["method"]?.string,method)
            XCTAssertEqual(result.object?["params"],params)
            let replay = try await client.request(payload,operationID:id)
            XCTAssertEqual(replay,result); XCTAssertEqual(calls[method],1)
        }
        for method in ["messages.search","availability"] {
            let result = try await client.request(.object(["method":.string(method),"params":params]))
            XCTAssertEqual(result.object?["method"]?.string,method)
            XCTAssertEqual(calls[method],1)
        }
    }

    func testScheduledAndWebhookOperationsReconcileAndStayKeyScoped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let databaseURL = directory.appendingPathComponent("fixture.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path,&database),SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database,"CREATE TABLE message (guid TEXT)",nil,nil,nil),SQLITE_OK)
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"Owner"), otherSecret = try keys.create(name:"Other")
        let owner = try XCTUnwrap(keys.authenticate(secret))
        let webhooks = try WebhookService(keys:keys,databaseURL:databaseURL,deliver:{ _ in XCTFail("No event watcher was started"); return false })
        let schedules = try LocalScheduleService(directory:directory.appendingPathComponent("schedules"),
            isKeyActive:{ id in keys.keys.contains { $0.id == id } },execute:{ _ in XCTFail("No scheduler was started"); return .null })
        let router = APIRouter(keys:keys,webhooks:webhooks,schedules:schedules) { _ in XCTFail("Service routes remain in the app"); return .null }
        let port = UInt16.random(in:20000...45000)
        let server = try LocalAPIServer(host:"127.0.0.1",port:port,router:router)
        defer { server.stop() }
        let ready = await withCheckedContinuation { continuation in
            let once = ExpandedReadyOnce(continuation); server.start { once.finish($0) }
        }
        XCTAssertTrue(ready)
        let base = URL(string:"http://127.0.0.1:\(port)")!
        let client = BBCHTTPClient(baseURL:base,apiKey:secret), other = BBCHTTPClient(baseURL:base,apiKey:otherSecret)
        let id = UUID()
        let payload: BBCJSONValue = .object(["method":.string("schedule.create"),"params":.object([
            "send_at":.string(ISO8601DateFormatter().string(from:Date().addingTimeInterval(3600))),
            "message":.object(["to":.string("fixture@example.test"),"text":.string("scheduled fixture")])])])
        let created = try await client.request(payload,operationID:id)
        XCTAssertEqual(created.object?["schedule_id"]?.string,id.uuidString)
        let replay = try await client.request(payload,operationID:id)
        XCTAssertEqual(replay,created)
        // Simulate a crash after the queue was saved but before the API's final
        // create receipt. Reconciliation uses the already-known operation UUID.
        let ledger = directory.appendingPathComponent("operation-\(owner)-\(id).json")
        let saved = try JSONDecoder().decode(APIRouter.Operation.self,from:Data(contentsOf:ledger))
        try JSONEncoder().encode(APIRouter.Operation(fingerprint:saved.fingerprint)).write(to:ledger,options:.atomic)
        do { _ = try await client.request(payload,operationID:id); XCTFail("Reserved intent must not be replayed") }
        catch { }
        let target: BBCJSONValue = .object(["schedule_id":.string(id.uuidString)])
        let reconciled = try await client.request(.object(["method":.string("schedule.get"),"params":target]))
        XCTAssertEqual(reconciled.object?["state"]?.string,"pending")
        let ownList = try await client.request(.object(["method":.string("schedule.list")]))
        XCTAssertEqual(ownList.object?["schedules"]?.fixtureArray?.count,1)
        let otherList = try await other.request(.object(["method":.string("schedule.list")]))
        XCTAssertEqual(otherList.object?["schedules"]?.fixtureArray?.count,0)
        do { _ = try await other.request(.object(["method":.string("schedule.get"),"params":target])); XCTFail("Another key cannot inspect the schedule") }
        catch { }
        let cancelled = try await client.request(.object(["method":.string("schedule.cancel"),"params":target]),operationID:UUID())
        XCTAssertEqual(cancelled.object?["state"]?.string,"cancelled")

        let register: BBCJSONValue = .object(["method":.string("webhooks.register"),"params":.object(["url":.string("https://example.test/events")])])
        let registrationID = UUID(), registered = try await client.request(register,operationID:registrationID)
        let repeated = try await client.request(register,operationID:registrationID)
        XCTAssertEqual(repeated,registered)
        let webhookID = try XCTUnwrap(registered.object?["webhook_id"]?.string)
        let listed = try await client.request(.object(["method":.string("webhooks.list")]))
        XCTAssertEqual(listed.object?["webhooks"]?.fixtureArray?.count,1)
        let hidden = try await other.request(.object(["method":.string("webhooks.list")]))
        XCTAssertEqual(hidden.object?["webhooks"]?.fixtureArray?.count,0)
        _ = try await client.request(.object(["method":.string("webhooks.remove"),"params":.object(["webhook_id":.string(webhookID)])]),operationID:UUID())
        let removed = try await client.request(.object(["method":.string("webhooks.list")]))
        XCTAssertEqual(removed.object?["webhooks"]?.fixtureArray?.count,0)
    }
}

private extension BBCJSONValue {
    var fixtureArray: [BBCJSONValue]? { if case .array(let values) = self { values } else { nil } }
}

private final class ExpandedReadyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool,Never>?
    init(_ continuation: CheckedContinuation<Bool,Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(returning:value)
    }
}
