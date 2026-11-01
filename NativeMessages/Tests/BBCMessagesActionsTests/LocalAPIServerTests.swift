import Foundation
import XCTest
import BBCClient
@testable import BBCMessagesActions

@MainActor final class LocalAPIServerTests: XCTestCase {
    func testClientNetworkRestrictionIgnoresForwardedHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let keys = try APIKeyStore(directory:directory), secret = try keys.create(name:"IP fixture")
        var calls = 0
        let router = APIRouter(keys:keys) { _ in calls += 1; return .null }
        let port = UInt16.random(in:20000...45000)
        let server = try LocalAPIServer(host:"127.0.0.1",port:port,router:router,allowedNetworks:try IPNetwork.parseList("10.0.0.0/8"))
        defer { server.stop() }
        let ready = await withCheckedContinuation { continuation in
            let once = ReadyOnce(continuation); server.start { once.finish($0) }
        }
        XCTAssertTrue(ready)
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/v1/status")!)
        request.setValue("Bearer "+secret,forHTTPHeaderField:"Authorization")
        request.setValue("10.0.0.1",forHTTPHeaderField:"X-Forwarded-For")
        request.setValue("for=10.0.0.1",forHTTPHeaderField:"Forwarded")
        let (data,response) = try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,403)
        XCTAssertEqual(try JSONDecoder().decode(BBCJSONValue.self,from:data).object?["error"]?.string,"client_address_denied")
        XCTAssertEqual(calls,0)
    }
    func testEmbeddedListenerAuthenticatesBeforeCallingTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory), key = try keys.create(name: "HTTP fixture")
        var calls = 0
        let router = APIRouter(keys: keys) { _ in calls += 1; return .object(["version": .string("fixture")]) }
        let port = UInt16.random(in: 20000...45000)
        let server = try LocalAPIServer(host: "127.0.0.1", port: port, router: router)
        defer { server.stop() }
        let ready = await withCheckedContinuation { continuation in
            let once = ReadyOnce(continuation)
            server.start { once.finish($0) }
        }
        XCTAssertTrue(ready)
        let url = URL(string: "http://127.0.0.1:\(port)/v1/status")!
        let (_, rejected) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 401); XCTAssertEqual(calls, 0)
        let response = try await BBCHTTPClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: key).request(.object(["method": .string("status")]))
        XCTAssertEqual(response.object?["version"]?.string, "fixture"); XCTAssertEqual(calls, 1)
        let client = BBCHTTPClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: key)
        let original = try RichMessagingTests.png() + Data(repeating: 0, count: 100_000)
        let upload = try await client.uploadMedia(original, filename: "photo.png")
        let id = try XCTUnwrap(upload.object?["media_id"]?.string)
        let file = try MediaStore(directory: directory.appendingPathComponent("media")).resolve(id).1
        XCTAssertEqual(try Data(contentsOf: file), original); XCTAssertEqual(calls, 1)
        let download = try await client.request(.object(["method": .string("media.download"), "params": .object([:])]))
        XCTAssertEqual(download.object?["version"]?.string, "fixture"); XCTAssertEqual(calls, 2)

    }
}
private final class ReadyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) { lock.lock(); let result = continuation; continuation = nil; lock.unlock(); result?.resume(returning: value) }
}
