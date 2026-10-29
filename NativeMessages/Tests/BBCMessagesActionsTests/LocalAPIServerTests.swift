import Foundation
import XCTest
import BBCClient
@testable import BBCMessagesActions

@MainActor final class LocalAPIServerTests: XCTestCase {
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
    }
}
private final class ReadyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) { lock.lock(); let result = continuation; continuation = nil; lock.unlock(); result?.resume(returning: value) }
}
