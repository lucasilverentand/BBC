import Foundation
import Network
import XCTest
import BBCClient
@testable import BBCMessagesActions

final class ClientNetworkTests: XCTestCase {
    func testIPv4AndIPv6NetworkBoundaries() throws {
        let v4 = try IPNetwork("192.168.1.40/24")
        XCTAssertTrue(v4.contains(try XCTUnwrap(IPNetwork.address("192.168.1.255"))))
        XCTAssertFalse(v4.contains(try XCTUnwrap(IPNetwork.address("192.168.2.1"))))
        XCTAssertTrue(v4.contains(try XCTUnwrap(IPNetwork.address("::ffff:192.168.1.20"))))
        let v6 = try IPNetwork("fd12:3456::/33")
        XCTAssertTrue(v6.contains(try XCTUnwrap(IPNetwork.address("fd12:3456:7fff::1"))))
        XCTAssertFalse(v6.contains(try XCTUnwrap(IPNetwork.address("fd12:3456:8000::1"))))
        XCTAssertFalse(v6.contains(try XCTUnwrap(IPNetwork.address("192.168.1.1"))))
        XCTAssertTrue(try IPNetwork("0.0.0.0/0").contains(IPNetwork.address("203.0.113.9")!))
        XCTAssertFalse(try IPNetwork("::1").contains(IPNetwork.address("::2")!))
    }
    func testInvalidRulesNeverBecomeAnUnrestrictedPolicy() throws {
        for text in ["localhost","192.168.1.1/33","::/129","10.0.0.0/-1","10.0.0.0/","10.0.0.0/8/1","10.0.0.1\u{0}","::1%lo0"] {
            XCTAssertThrowsError(try IPNetwork.parseList(text),text)
        }
        XCTAssertEqual(try IPNetwork.parseList("127.0.0.1\n::1,10.0.0.0/8").count,3)
        let endpoint = NWEndpoint.hostPort(host:"127.0.0.1",port:1234)
        XCTAssertFalse(IPNetwork.permits(endpoint,rules:try IPNetwork.parseList("10.0.0.0/8")))
        XCTAssertTrue(IPNetwork.permits(endpoint,rules:try IPNetwork.parseList("127.0.0.1")))
    }
}

@MainActor final class KeyAccessTests: XCTestCase {
    private func fixture(_ body: (APIKeyStore,URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        try await body(APIKeyStore(directory:directory),directory)
    }
    func testKeyPermissionsPersistAndOldKeysKeepTheirAccess() async throws {
        try await fixture { keys,directory in
            let secret = try keys.create(name:"Observer",access:.readOnly), id = try XCTUnwrap(keys.authenticate(secret))
            XCTAssertFalse(keys.allows(id,method:"send")); XCTAssertTrue(keys.allows(id,method:"webhooks.register"))
            let restored = try APIKeyStore(directory:directory)
            XCTAssertFalse(restored.allows(id,method:"send"))
            let file = directory.appendingPathComponent("keys.json")
            var records = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [[String:Any]]
            XCTAssertFalse(String(decoding:try Data(contentsOf:file),as:UTF8.self).contains(secret))
            records[0].removeValue(forKey:"access")
            try JSONSerialization.data(withJSONObject:records).write(to:file)
            XCTAssertTrue(try APIKeyStore(directory:directory).allows(id,method:"send"))
            records[0]["access"] = "unknown-future-scope"
            try JSONSerialization.data(withJSONObject:records).write(to:file)
            XCTAssertFalse(try APIKeyStore(directory:directory).allows(id,method:"send"))
        }
    }
    func testDowngradeBlocksReplayAndUpgradeDoesNotRotateSecret() async throws {
        try await fixture { keys,directory in
            let secret = try keys.create(name:"Client",access:.full), id = try XCTUnwrap(keys.authenticate(secret))
            var calls = 0
            let router = APIRouter(keys:keys) { _ in calls += 1; return .object(["ok":.bool(true)]) }
            let headers = ["authorization":"Bearer "+secret,"idempotency-key":UUID().uuidString]
            let data = Data("{}".utf8)
            let first = await router.handle(method:"POST",path:"/v1/messages",headers:headers,body:data)
            XCTAssertEqual(first.status,200); XCTAssertEqual(calls,1)
            try keys.updateAccess(id,access:.readOnly)
            let denied = await router.handle(method:"POST",path:"/v1/messages",headers:headers,body:data)
            XCTAssertEqual(denied.status,403); XCTAssertEqual(denied.value.object?["error"]?.string,"key_readonly"); XCTAssertEqual(calls,1)
            try keys.updateAccess(id,access:.full)
            XCTAssertEqual(keys.authenticate(secret),id)
            let replay = await router.handle(method:"POST",path:"/v1/messages",headers:headers,body:data)
            XCTAssertEqual(replay.value,first.value); XCTAssertEqual(calls,1)
        }
    }
    func testReadOnlyKeyCannotWriteInFullAccountAndStatusIsFiltered() async throws {
        try await fixture { keys,directory in
            let secret = try keys.create(name:"Observer",access:.readOnly)
            let router = APIRouter(keys:keys) { request in
                XCTAssertEqual(request.object?["method"]?.string,"status")
                return .object(["methods":.array([.string("send"),.string("messages.search"),.string("future.write")])])
            }
            let headers = ["authorization":"Bearer "+secret,"idempotency-key":UUID().uuidString]
            for path in ["/v1/messages","/v1/tapbacks","/v1/read","/v1/typing/start","/v1/groups/create","/v1/schedules/create","/v1/media/upload"] {
                let response = await router.handle(method:"POST",path:path,headers:headers,body:Data("{}".utf8))
                XCTAssertEqual(response.status,403,path)
            }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:directory.path).contains { $0.hasPrefix("operation-") })
            let status = await router.handle(method:"GET",path:"/v1/status",headers:headers,body:Data())
            XCTAssertEqual(status.value.object?["key_access"]?.string,"read-only")
            XCTAssertEqual(status.value.object?["methods"],.array([.string("messages.search")]))
        }
    }
    func testAccountModeStillLimitsFullKey() async throws {
        try await fixture { keys,_ in
            let secret = try keys.create(name:"Full",access:.full)
            let router = APIRouter(keys:keys,mode:.readOnly) { _ in XCTFail("Must not dispatch"); return .null }
            let result = await router.handle(method:"POST",path:"/v1/messages",headers:["authorization":"Bearer "+secret],body:Data("{}".utf8))
            XCTAssertEqual(result.status,403); XCTAssertEqual(result.value.object?["error"]?.string,"readonly_mode")
        }
    }
    func testRevocationDuringStatusDoesNotReturnPermissionsOrCrash() async throws {
        try await fixture { keys,_ in
            let secret = try keys.create(name:"Temporary"), id = try XCTUnwrap(keys.authenticate(secret))
            let router = APIRouter(keys:keys) { _ in try keys.revoke(id); return .object(["methods":.array([])]) }
            let result = await router.handle(method:"GET",path:"/v1/status",headers:["authorization":"Bearer "+secret],body:Data())
            XCTAssertEqual(result.status,401)
        }
    }
    func testDowngradedKeyCannotDispatchItsPendingSchedule() async throws {
        try await fixture { keys,directory in
            let secret = try keys.create(name:"Scheduler",access:.full), id = try XCTUnwrap(keys.authenticate(secret))
            var clock = Date(), calls = 0
            let schedules = try LocalScheduleService(directory:directory.appendingPathComponent("schedules"),isKeyActive:{ keys.allows($0,method:"send") },execute:{ _ in calls += 1; return .null },now:{ clock })
            _ = try schedules.handle(method:"schedule.create",params:["send_at":.string(ISO8601DateFormatter().string(from:clock.addingTimeInterval(60))),"message":.object(["to":.string("fixture@example.test"),"text":.string("fixture")])],keyID:id,operationID:UUID())
            try keys.updateAccess(id,access:.readOnly)
            clock.addTimeInterval(61); schedules.start(polling:false); await schedules.tick(); schedules.stop()
            XCTAssertEqual(calls,0)
            let records = try JSONDecoder().decode([LocalScheduleService.Record].self,from:Data(contentsOf:directory.appendingPathComponent("schedules/schedules.json")))
            XCTAssertEqual(records.first?.state,"cancelled")
        }
    }
}
