import Foundation
import XCTest
import BBCClient
@testable import BBCMessagesActions

@MainActor final class KeyRotationTests: XCTestCase {
    func testRotationReplacesSecretAndKeepsIdentitySettingsAndReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory)
        let old = try keys.create(name: "Integration", access: .readOnly, allowedClients: "127.0.0.0/8", allowNetwork: true)
        let original = try XCTUnwrap(keys.keys.first)
        let operationID = UUID()
        let receipt = APIRouter.Operation(fingerprint: "fixture", result: .object(["ok": .bool(true)]))
        let file = directory.appendingPathComponent("operation-\(original.id)-\(operationID).json")
        try JSONEncoder().encode(receipt).write(to: file)
        let router = APIRouter(keys: keys) { _ in XCTFail("Receipt read must not dispatch"); return .null }
        let new = try keys.rotate(original.id)
        XCTAssertNotEqual(new, old)
        XCTAssertNil(keys.authenticate(old))
        XCTAssertEqual(keys.authenticate(new), original.id)
        let restored = try APIKeyStore(directory: directory)
        XCTAssertNil(restored.authenticate(old))
        XCTAssertEqual(restored.authenticate(new), original.id)
        let record = try XCTUnwrap(restored.keys.first)
        XCTAssertEqual(record.name, original.name)
        XCTAssertEqual(record.createdAt, original.createdAt)
        XCTAssertEqual(record.access, original.access)
        XCTAssertEqual(record.allowNetwork, original.allowNetwork)
        XCTAssertEqual(record.allowedClients, original.allowedClients)
        let path = "/v1/operations/\(operationID)"
        let rejected = await router.handle(method: "GET", path: path, headers: ["authorization": "Bearer " + old], body: Data())
        XCTAssertEqual(rejected.status, 401)
        let accepted = await router.handle(method: "GET", path: path, headers: ["authorization": "Bearer " + new], body: Data())
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(accepted.value.object?["ok"]?.bool, true)
        let stored = try String(contentsOf: directory.appendingPathComponent("keys.json"), encoding: .utf8)
        XCTAssertFalse(stored.contains(new)); XCTAssertFalse(stored.contains(old))
    }

    func testFailedSaveKeepsOldSecretActive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory)
        let old = try keys.create(name: "Integration")
        let id = try XCTUnwrap(keys.authenticate(old))
        let file = directory.appendingPathComponent("keys.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try keys.rotate(id))
        XCTAssertEqual(keys.authenticate(old), id)
        XCTAssertThrowsError(try keys.rotate(UUID()))
    }
}
