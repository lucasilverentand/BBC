import Foundation
import XCTest
import Network
import BBCClient
@testable import BBCMessagesActions

@MainActor final class LocalAPIServerTests: XCTestCase {
    func testClientNetworkRestrictionIgnoresForwardedHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"IP fixture", allowedClients:"10.0.0.0/8")
        var calls = 0
        let router = APIRouter(keys:keys) { _ in calls += 1; return .object(["version": .string("fixture")]) }
        let (server, port, base) = try await startFixtureServer(router: router)
        defer { server.stopAndDrain() }
        var request = URLRequest(url:base.appendingPathComponent("v1/status"))
        request.setValue("Bearer "+secret,forHTTPHeaderField:"Authorization")
        request.setValue("10.0.0.1",forHTTPHeaderField:"X-Forwarded-For")
        request.setValue("for=10.0.0.1",forHTTPHeaderField:"Forwarded")
        let (data,response) = try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,403)
        XCTAssertEqual(try JSONDecoder().decode(BBCJSONValue.self,from:data).object?["error"]?.string,"client_address_denied")
        XCTAssertEqual(calls,0)
        let otherSecret = try keys.create(name: "Local fixture", allowedClients: "127.0.0.1")
        request.setValue("Bearer " + otherSecret, forHTTPHeaderField: "Authorization")
        let (_, allowed) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((allowed as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(calls, 1)
        let id = try XCTUnwrap(keys.authenticate(secret))
        try keys.update(id, access: .readOnly, allowedClients: "127.0.0.0/8")
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        let (_, updated) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((updated as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try APIKeyStore(directory: directory).keys.first { $0.id == id }?.allowedClients, "127.0.0.0/8")
    }
    func testLegacyClientRulesAreInheritedAndPersistedPerToken() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory)
        _ = try keys.create(name: "Legacy")
        let file = directory.appendingPathComponent("keys.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        records[0].removeValue(forKey: "allowedClients")
        try JSONSerialization.data(withJSONObject: records).write(to: file)
        let migrated = try APIKeyStore(directory: directory, legacyAllowedClients: "10.0.0.0/8")
        XCTAssertEqual(migrated.keys[0].allowedClients, "10.0.0.0/8")
        XCTAssertEqual(try APIKeyStore(directory: directory, legacyAllowedClients: "").keys[0].allowedClients, "10.0.0.0/8")
        XCTAssertThrowsError(try migrated.update(migrated.keys[0].id, access: .full, allowedClients: "invalid"))
        XCTAssertEqual(migrated.keys[0].allowedClients, "10.0.0.0/8")
        _ = try migrated.create(name: "New")
        XCTAssertEqual(migrated.keys[1].allowedClients, "")
    }
    func testLegacyReadOnlyModeDowngradesKeysDurably() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try APIKeyStore(directory: directory)
        let secret = try original.create(name: "Former full key", access: .full)
        let migrated = try APIKeyStore(directory: directory, legacyMode: .readOnly)
        let id = try XCTUnwrap(migrated.authenticate(secret))
        XCTAssertFalse(migrated.allows(id, method: "send"))
        XCTAssertFalse(try APIKeyStore(directory: directory).allows(id, method: "send"))
        try migrated.updateAccess(id, access: .full)
        XCTAssertTrue(migrated.allows(id, method: "send"))
    }
    func testNetworkAccessIsPerTokenAndUpdatesWithoutRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory)
        let local = try keys.create(name: "Local")
        let remote = try keys.create(name: "Remote", allowedClients: "10.0.0.0/8", allowNetwork: true)
        var calls = 0
        let router = APIRouter(keys: keys) { _ in calls += 1; return .object([:]) }
        let peer = NWEndpoint.hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("10.2.3.4"))), port: 1234)
        func request(_ secret: String, peer: NWEndpoint) async -> APIRouter.Response {
            await router.handle(method: "GET", path: "/v1/status", headers: ["authorization": "Bearer " + secret], body: Data(), peer: peer)
        }
        let denied = await request(local, peer: peer)
        XCTAssertEqual(denied.status, 403)
        let allowed = await request(remote, peer: peer)
        XCTAssertEqual(allowed.status, 200)
        let outside = await request(remote, peer: .hostPort(host: .ipv4(try XCTUnwrap(IPv4Address("192.168.1.2"))), port: 1234))
        XCTAssertEqual(outside.status, 403)
        let id = try XCTUnwrap(keys.authenticate(remote))
        try keys.update(id, access: .readOnly, allowedClients: "", allowNetwork: false, name: "Renamed")
        let disabled = await request(remote, peer: peer)
        XCTAssertEqual(disabled.status, 403)
        let loopback = await request(remote, peer: .hostPort(host: .ipv4(.loopback), port: 1234))
        XCTAssertEqual(loopback.status, 200)
        let restored = try APIKeyStore(directory: directory)
        XCTAssertEqual(restored.keys.first { $0.id == id }?.name, "Renamed")
        XCTAssertEqual(restored.keys.first { $0.id == id }?.allowNetwork, false)
        XCTAssertFalse(keys.permits(id, endpoint: nil))
        XCTAssertEqual(calls, 2)
        try keys.revoke(id)
        let revoked = await request(remote, peer: peer)
        XCTAssertEqual(revoked.status, 401)
    }

    func testLegacyNetworkAccessIsInheritedOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory)
        _ = try keys.create(name: "Legacy")
        let file = directory.appendingPathComponent("keys.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        records[0].removeValue(forKey: "allowNetwork")
        try JSONSerialization.data(withJSONObject: records).write(to: file)
        let migrated = try APIKeyStore(directory: directory, legacyNetworkAccess: true)
        XCTAssertTrue(migrated.keys[0].allowNetwork)
        XCTAssertTrue(try APIKeyStore(directory: directory).keys[0].allowNetwork)
        _ = try migrated.create(name: "New")
        XCTAssertFalse(migrated.keys[1].allowNetwork)
    }

    func testEmbeddedListenerAuthenticatesBeforeCallingTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory), key = try keys.create(name: "HTTP fixture")
        var calls = 0
        let router = APIRouter(keys: keys) { _ in calls += 1; return .object(["version": .string("fixture")]) }
        let (server, port, base) = try await startFixtureServer(router: router)
        defer { server.stopAndDrain() }
        let url = base.appendingPathComponent("v1/status")
        let (_, rejected) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 401); XCTAssertEqual(calls, 0)
        let response = try await BBCHTTPClient(baseURL: base, apiKey: key).request(.object(["method": .string("status")]))
        XCTAssertEqual(response.object?["version"]?.string, "fixture"); XCTAssertEqual(calls, 1)
        let client = BBCHTTPClient(baseURL: base, apiKey: key)
        let original = try RichMessagingTests.png() + Data(repeating: 0, count: 100_000)
        let upload = try await client.uploadMedia(original, filename: "photo.png")
        let id = try XCTUnwrap(upload.object?["media_id"]?.string)
        let file = try MediaStore(directory: directory.appendingPathComponent("media")).resolve(id).1
        XCTAssertEqual(try Data(contentsOf: file), original); XCTAssertEqual(calls, 1)
        let download = try await client.request(.object(["method": .string("media.download"), "params": .object([:])]))
        XCTAssertEqual(download.object?["version"]?.string, "fixture"); XCTAssertEqual(calls, 2)

    }
}
