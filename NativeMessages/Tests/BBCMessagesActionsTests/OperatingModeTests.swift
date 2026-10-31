import Foundation
import XCTest
import SQLite3
import BBCClient
@testable import BBCMessagesActions

@MainActor final class OperatingModeTests: XCTestCase {
    private func fixture(_ run: (APIKeyStore, String, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory), secret = try keys.create(name: "Mode fixture")
        try await run(keys, secret, directory)
    }
    func testReadOnlyRejectsEverySendingRouteBeforeDispatchOrIntent() async throws {
        try await fixture { keys, secret, directory in
            let router = APIRouter(keys: keys, mode: .readOnly) { _ in XCTFail("Read-only denial must precede transport"); return .null }
            let paths = ["/v1/messages", "/v1/messages/edit", "/v1/messages/unsend", "/v1/messages/multipart",
                         "/v1/availability", "/v1/replies", "/v1/links", "/v1/tapbacks", "/v1/read",
                         "/v1/typing/start", "/v1/typing/stop", "/v1/groups/create", "/v1/groups/add",
                         "/v1/groups/remove", "/v1/groups/name", "/v1/groups/photo", "/v1/groups/leave",
                         "/v1/schedules/create", "/v1/schedules/update", "/v1/schedules/cancel", "/v1/schedules/get", "/v1/schedules/list"]
            for path in paths {
                let result = await router.handle(method: "POST", path: path,
                    headers: ["authorization": "Bearer " + secret, "idempotency-key": UUID().uuidString], body: Data("{}".utf8))
                XCTAssertEqual(result.status, 403, path)
                XCTAssertEqual(result.value.object?["error"]?.string, "readonly_mode", path)
                XCTAssertEqual(result.value.object?["uncertain"]?.bool, false, path)
            }
            let withoutOperation = await router.handle(method: "POST", path: "/v1/messages", headers: ["authorization": "Bearer " + secret], body: Data("{}".utf8))
            XCTAssertEqual(withoutOperation.status, 403)
            let upload = await router.handle(method: "POST", path: "/v1/media/upload",
                headers: ["authorization": "Bearer " + secret, "x-bbc-filename": "fixture.png"], body: Data([0x89, 0x50, 0x4e, 0x47]))
            XCTAssertEqual(upload.status, 403)
            XCTAssertEqual(upload.value.object?["error"]?.string, "readonly_mode")
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(files.contains { $0.hasPrefix("operation-") })
            XCTAssertFalse(files.contains("media"))
            XCTAssertFalse(files.contains("schedules"))
        }
    }
    func testReadOnlyDoesNotReturnAnOldMutationAsAReplay() async throws {
        try await fixture { keys, secret, directory in
            let id = UUID(), keyID = try XCTUnwrap(keys.authenticate(secret))
            let headers = ["authorization": "Bearer " + secret, "idempotency-key": id.uuidString]
            let body = Data(#"{"to":"fixture@example.test","text":"fixture"}"#.utf8)
            var sends = 0
            let full = APIRouter(keys: keys) { _ in sends += 1; return .object(["ok": .bool(true), "guid": .string("old receipt")]) }
            let original = await full.handle(method: "POST", path: "/v1/messages", headers: headers, body: body)
            XCTAssertEqual(original.status, 200); XCTAssertEqual(sends, 1)
            let file = directory.appendingPathComponent("operation-\(keyID)-\(id).json"), saved = try Data(contentsOf: file)
            let observer = APIRouter(keys: keys, mode: .readOnly) { _ in XCTFail("A saved receipt cannot bypass mode policy"); return .null }
            let replay = await observer.handle(method: "POST", path: "/v1/messages", headers: headers, body: body)
            XCTAssertEqual(replay.status, 403)
            XCTAssertEqual(replay.value.object?["error"]?.string, "readonly_mode")
            XCTAssertEqual(try Data(contentsOf: file), saved)
            // Receipt observation remains available for reconciliation.
            let observed = await observer.handle(method: "GET", path: "/v1/operations/" + id.uuidString, headers: headers, body: Data())
            XCTAssertEqual(observed.status, 200); XCTAssertEqual(observed.value, original.value)
        }
    }
    func testReadOnlyStatusFiltersUnsafeUpstreamCapabilities() async throws {
        try await fixture { keys, secret, _ in
            let safe = ["status", "messages.after", "messages.status", "messages.search", "media.download", "read.status", "media.visual", "media.transcribe"]
            let unsafe = ["send", "reply", "tapback", "read", "typing", "availability", "groups.create", "schedule.create", "future.native.action"]
            let router = APIRouter(keys: keys, mode: .readOnly) { request in
                XCTAssertEqual(request.object?["method"]?.string, "status")
                return .object(["methods": .array((safe + unsafe).map(BBCJSONValue.string) + [.number(7)]),
                    "native_bridge_ready": .bool(true), "native_bridge": .object(["ready": .bool(true), "capabilities": .array([.string("tapback")])])])
            }
            let status = await router.handle(method: "GET", path: "/v1/status", headers: ["authorization": "Bearer " + secret], body: Data())
            XCTAssertEqual(status.status, 200)
            XCTAssertEqual(status.value.object?["operating_mode"]?.string, "read-only")
            XCTAssertEqual(status.value.object?["native_bridge_ready"]?.bool, false)
            XCTAssertEqual(status.value.object?["native_bridge"]?.object?["capabilities"], .array([]))
            guard case .array(let methods) = status.value.object?["methods"] else { return XCTFail("Missing methods") }
            XCTAssertEqual(Set(methods.compactMap(\.string)), Set(safe))
            XCTAssertFalse(OperatingMode.readOnly.allows(method: "future.native.action"))
        }
    }
    func testReadOnlyObservationRoutesPreserveTheirExactParameters() async throws {
        try await fixture { keys, secret, directory in
            var calls: [String] = []
            let params: BBCJSONValue = .object(["fixture": .string("exact target")])
            let router = APIRouter(keys: keys, mode: .readOnly) { request in
                calls.append(try XCTUnwrap(request.object?["method"]?.string))
                XCTAssertEqual(request.object?["params"], params)
                return .object(["ok": .bool(true)])
            }
            for (path, method) in [("/v1/messages/after", "messages.after"), ("/v1/messages/status", "messages.status"),
                ("/v1/messages/search", "messages.search"), ("/v1/media/download", "media.download"),
                ("/v1/read/status", "read.status"), ("/v1/media/visual", "media.visual"), ("/v1/media/transcribe", "media.transcribe")] {
                let response = await router.handle(method: "POST", path: path, headers: ["authorization": "Bearer " + secret], body: try JSONEncoder().encode(params))
                XCTAssertEqual(response.status, 200)
                XCTAssertEqual(calls.last, method)
            }
            XCTAssertEqual(calls.count, 7)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("operation-") })
        }
    }
    func testReadOnlyAllowsAuthenticatedWebhookSetupAndRemoval() async throws {
        try await fixture { keys, secret, directory in
            let database = directory.appendingPathComponent("fixture.db")
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
            defer { sqlite3_close(connection) }
            XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE message(guid TEXT)", nil, nil, nil), SQLITE_OK)
            let webhooks = try WebhookService(keys: keys, databaseURL: database, deliver: { _ in XCTFail("Registration does not dispatch a webhook"); return false })
            let router = APIRouter(keys: keys, webhooks: webhooks, mode: .readOnly) { _ in XCTFail("Webhook configuration stays local"); return .null }
            let body = Data(#"{"url":"https://fixture.invalid/events"}"#.utf8)
            let headers = ["authorization": "Bearer " + secret, "idempotency-key": UUID().uuidString]
            let registered = await router.handle(method: "POST", path: "/v1/webhooks/register", headers: headers, body: body)
            XCTAssertEqual(registered.status, 200); XCTAssertEqual(registered.value.object?["ok"]?.bool, true)
            let replay = await router.handle(method: "POST", path: "/v1/webhooks/register", headers: headers, body: body)
            XCTAssertEqual(replay.value, registered.value)
            let listed = await router.handle(method: "POST", path: "/v1/webhooks/list", headers: ["authorization": "Bearer " + secret], body: Data("{}".utf8))
            guard case .array(let subscriptions) = listed.value.object?["webhooks"] else { return XCTFail("Missing subscriptions") }
            XCTAssertEqual(subscriptions.count, 1)
            let id = try XCTUnwrap(registered.value.object?["webhook_id"])
            let removed = await router.handle(method: "POST", path: "/v1/webhooks/remove",
                headers: ["authorization": "Bearer " + secret, "idempotency-key": UUID().uuidString], body: try JSONEncoder().encode(BBCJSONValue.object(["webhook_id": id])))
            XCTAssertEqual(removed.status, 200); XCTAssertEqual(removed.value.object?["ok"]?.bool, true)
            XCTAssertTrue(webhooks.state.subscriptions.isEmpty)
        }
    }
    func testAuthenticationStillPrecedesReadOnlyPolicy() async throws {
        try await fixture { keys, _, directory in
            let router = APIRouter(keys: keys, mode: .readOnly) { _ in XCTFail("Unauthenticated request"); return .null }
            let response = await router.handle(method: "POST", path: "/v1/messages", headers: [:], body: Data("{}".utf8))
            XCTAssertEqual(response.status, 401)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("operation-") })
        }
    }
    func testReadOnlyServiceStartupCannotActivateAPendingSchedule() async throws {
        try await fixture { keys, secret, directory in
            let keyID = try XCTUnwrap(keys.authenticate(secret)), id = UUID()
            var clock = Date(timeIntervalSince1970: 1_800_000_000), sends = 0
            let schedules = try LocalScheduleService(directory: directory.appendingPathComponent("schedules"),
                isKeyActive: { $0 == keyID }, execute: { _ in sends += 1; return .object(["ok": .bool(true)]) }, now: { clock })
            _ = try schedules.handle(method: "schedule.create", params: [
                "send_at": .string(ISO8601DateFormatter().string(from: clock.addingTimeInterval(60))),
                "message": .object(["to": .string("fixture@example.test"), "text": .string("fixture")])], keyID: keyID, operationID: id)
            clock.addTimeInterval(61)
            let router = APIRouter(keys: keys, schedules: schedules, mode: .readOnly) { _ in XCTFail("No transport call"); return .null }
            defer { router.stop() }
            router.startServices(); await schedules.tick()
            XCTAssertEqual(sends, 0)
            let pending = try schedules.handle(method: "schedule.get", params: ["schedule_id": .string(id.uuidString)], keyID: keyID)
            XCTAssertEqual(pending.object?["state"]?.string, "pending")
        }
    }
}
