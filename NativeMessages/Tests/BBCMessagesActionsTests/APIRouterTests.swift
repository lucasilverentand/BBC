import Foundation
import XCTest
import BBCClient
@testable import BBCMessagesActions

@MainActor final class APIRouterTests: XCTestCase {
    private func fixture(_ run: (APIKeyStore, String, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory), secret = try keys.create(name: "Fixture")
        try await run(keys, secret, directory)
    }
    func testKeysPersistOnlyHashesAndRevocationSurvivesRestart() async throws {
        try await fixture { keys, secret, directory in
            XCTAssertNotNil(keys.authenticate(secret)); XCTAssertNil(keys.authenticate("wrong"))
            XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("keys.json"), encoding: .utf8).contains(secret))
            let restored = try APIKeyStore(directory: directory)
            XCTAssertNotNil(restored.authenticate(secret))
            try restored.revoke(restored.keys[0].id)
            XCTAssertNil(try APIKeyStore(directory: directory).authenticate(secret))
        }
    }
    func testUnauthorizedRequestsCannotReadOrSend() async throws {
        try await fixture { keys, _, _ in
            let router = APIRouter(keys: keys) { _ in XCTFail("Must authenticate before transport"); return .null }
            let response = await router.handle(method: "GET", path: "/v1/status", headers: [:], body: Data())
            XCTAssertEqual(response.status, 401)
        }
    }
    func testDuplicateOperationReturnsReceiptWithoutAnotherNativeDispatchAcrossRestart() async throws {
        try await fixture { keys, secret, _ in
            var calls = 0
            let headers = ["authorization":"Bearer " + secret, "idempotency-key":UUID().uuidString]
            let body = Data(#"{"to":"fixture@example.test","text":"fixture"}"#.utf8)
            let router = APIRouter(keys: keys) { request in
                calls += 1
                XCTAssertEqual(request.object?["params"]?.object?["service"]?.string, "imessage")
                return .object(["ok": .bool(true), "guid": .string("receipt")])
            }
            let first = await router.handle(method: "POST", path: "/v1/messages", headers: headers, body: body)
            let restored = APIRouter(keys: keys) { _ in calls += 1; return .null }
            let duplicate = await restored.handle(method: "POST", path: "/v1/messages", headers: headers, body: body)
            XCTAssertEqual(first.value, duplicate.value); XCTAssertEqual(calls, 1)
            let changed = await router.handle(method: "POST", path: "/v1/messages", headers: headers, body: Data(#"{"text":"changed"}"#.utf8))
            XCTAssertEqual(changed.status, 409); XCTAssertEqual(calls, 1)
        }
    }
    func testUnknownDispatchOutcomeCannotBeAutomaticallyReplayed() async throws {
        try await fixture { keys, secret, directory in
            let id = UUID(), key = keys.keys[0].id
            let payload: BBCJSONValue = .object(["method": .string("send"), "params": .object(["service": .string("imessage"), "allow_sms_fallback": .bool(false)])])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let hash = APIKeyStore.digest(String(decoding: try encoder.encode(payload), as: UTF8.self))
            try encoder.encode(APIRouter.Operation(fingerprint: hash)).write(to: directory.appendingPathComponent("operation-\(key)-\(id).json"))
            let router = APIRouter(keys: keys) { _ in XCTFail("Never replay a reserved operation"); return .null }
            let result = await router.handle(method: "POST", path: "/v1/messages", headers: ["authorization":"Bearer " + secret,"idempotency-key":id.uuidString], body: Data("{}".utf8))
            XCTAssertEqual(result.status, 409); XCTAssertEqual(result.value.object?["uncertain"]?.bool, true)
        }
    }
    func testMutationsRequireUUIDAndRevokeImmediatelyBlocksRequests() async throws {
        try await fixture { keys, secret, _ in
            let router = APIRouter(keys: keys) { _ in XCTFail("Must not dispatch"); return .null }
            let headers = ["authorization":"Bearer " + secret]
            let missing = await router.handle(method: "POST", path: "/v1/messages", headers: headers, body: Data("{}".utf8))
            XCTAssertEqual(missing.status, 400)
            try keys.revoke(keys.keys[0].id)
            let revoked = await router.handle(method: "GET", path: "/v1/status", headers: headers, body: Data())
            XCTAssertEqual(revoked.status, 401)
        }
    }
    func testReadOnlyPagesNeedNoMutationKeyAndPreserveThreadRoots() async throws {
        try await fixture { keys, secret, _ in
            let router = APIRouter(keys: keys) { request in
                XCTAssertEqual(request.object?["method"]?.string, "messages.after")
                return .object(["messages": .array([.object(["guid": .string("child"), "reply_to_guid": .string("root"), "thread_root_guid": .string("root")])])])
            }
            let response = await router.handle(method: "POST", path: "/v1/messages/after", headers: ["authorization":"Bearer " + secret], body: Data("{}".utf8))
            XCTAssertEqual(response.status, 200)
            guard case .array(let rows) = response.value.object?["messages"] else { return XCTFail("Expected rows") }
            XCTAssertEqual(rows[0].object?["thread_root_guid"]?.string, "root")
        }
    }

    func testUIResetRequiresAnOperationAndReplaysOnlyItsReceipt() async throws {
        try await fixture { keys, secret, _ in
            var calls = 0
            let router = APIRouter(keys: keys) { request in
                calls += 1
                XCTAssertEqual(request.object?["method"]?.string, "ui.reset")
                XCTAssertEqual(request.object?["params"], .null)
                return .object(["ok": .bool(true), "ui_state": .string("clean")])
            }
            var headers = ["authorization": "Bearer " + secret]
            let missing = await router.handle(method: "POST", path: "/v1/ui/reset", headers: headers, body: Data("{}".utf8))
            XCTAssertEqual(missing.status, 400); XCTAssertEqual(calls, 0)
            headers["idempotency-key"] = UUID().uuidString
            let first = await router.handle(method: "POST", path: "/v1/ui/reset", headers: headers, body: Data("{}".utf8))
            let replay = await router.handle(method: "POST", path: "/v1/ui/reset", headers: headers, body: Data("{}".utf8))
            XCTAssertEqual(first.value, replay.value); XCTAssertEqual(calls, 1)
            let discard = await router.handle(method: "POST", path: "/v1/ui/reset", headers: headers, body: Data(#"{"discard_draft":true}"#.utf8))
            XCTAssertEqual(discard.status, 400); XCTAssertEqual(calls, 1)
        }
    }
}
