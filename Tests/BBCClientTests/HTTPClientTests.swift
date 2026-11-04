import Foundation
import XCTest
@testable import BBCClient

/// A real HTTP peer on an ephemeral loopback port. It never invokes the Mac app.
final class HTTPClientTests: XCTestCase, @unchecked Sendable {
    private func withPeer(status: Int = 200, response: String = "{\"ok\":true}", redirect: Bool = false,
                          run: (BBCHTTPClient, () throws -> [[String: BBCJSONValue]]) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("peer.py")
        let portFile = directory.appendingPathComponent("port")
        let callsFile = directory.appendingPathComponent("calls")
        try Data(response.utf8).write(to: directory.appendingPathComponent("response"))
        try Data("""
        import http.server, json, pathlib, sys
        root = pathlib.Path(sys.argv[1])
        class Peer(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self): self.respond()
            def do_POST(self): self.respond()
            def respond(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                with (root / 'calls').open('a') as calls:
                    calls.write(json.dumps({'path': self.path, 'method': self.command,
                                            'headers': dict(self.headers), 'body': body.decode()}) + '\\n')
                self.send_response(int(sys.argv[2]))
                if sys.argv[3] == 'true':
                    self.send_header('Location', 'http://127.0.0.1:%d/redirected' % self.server.server_port)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write((root / 'response').read_bytes())
        server = http.server.HTTPServer(('127.0.0.1', 0), Peer)
        (root / 'port').write_text(str(server.server_port))
        server.serve_forever()
        """.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, directory.path, String(status), String(redirect)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Foundation reaps Process children. Blocking waitUntilExit here can deadlock
        // an async XCTest executor after a child has already exited.
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: portFile.path), process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let client = BBCHTTPClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: "fixture-only-key")
        try await run(client) {
            guard FileManager.default.fileExists(atPath: callsFile.path) else { return [] }
            return try String(contentsOf: callsFile, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode([String: BBCJSONValue].self, from: Data($0.utf8))
            }
        }
    }

    func testStatusUsesAuthenticatedGETWithoutBodyOrOperationID() async throws {
        try await withPeer { client, calls in
            let result = try await client.request(.object(["method": .string("status")]))
            XCTAssertEqual(result.object?["ok"], .bool(true))
            let request = try XCTUnwrap(calls().first)
            XCTAssertEqual(request["path"], .string("/v1/status"))
            XCTAssertEqual(request["method"], .string("GET"))
            XCTAssertEqual(request["body"], .string(""))
            XCTAssertEqual(request["headers"]?.object?["Authorization"], .string("Bearer fixture-only-key"))
            XCTAssertNil(request["headers"]?.object?["Idempotency-Key"])
        }
    }

    func testReplyKeepsExactIdentityAndPersistedOperationID() async throws {
        try await withPeer { client, calls in
            let id = UUID(), target = "p:3/01234567-89AB-CDEF-0123-456789ABCDEF"
            let params: BBCJSONValue = .object(["reply_to": .string(target), "text": .string("fixture only")])
            _ = try await client.request(.object(["method": .string("send"), "params": params]), operationID: id)
            let requests = try calls(), request = try XCTUnwrap(requests.first)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(request["path"], .string("/v1/replies"))
            XCTAssertEqual(request["method"], .string("POST"))
            XCTAssertEqual(request["headers"]?.object?["Idempotency-Key"], .string(id.uuidString))
            XCTAssertEqual(try JSONDecoder().decode(BBCJSONValue.self, from: Data(try XCTUnwrap(request["body"]?.string).utf8)), params)
        }
    }

    func testMutationsRequireOperationIDBeforeDispatch() async throws {
        try await withPeer { client, calls in
            for method in ["send", "tapback", "typing.start", "groups.create", "messages.edit", "schedule.create", "webhooks.register"] {
                do {
                    _ = try await client.request(.object(["method": .string(method)]))
                    XCTFail("Expected operation ID requirement for \(method)")
                } catch let error as BBCError {
                    guard case .invalid = error else { return XCTFail("Unexpected error: \(error)") }
                }
            }
            XCTAssertTrue(try calls().isEmpty)
        }
    }

    func testReadRoutesDoNotRequireOperationID() async throws {
        try await withPeer { client, calls in
            for (method, path) in [("messages.search", "messages/search"), ("schedule.list", "schedules/list"), ("availability", "availability")] {
                _ = try await client.request(.object(["method": .string(method)]))
                let request = try XCTUnwrap(calls().last)
                XCTAssertEqual(request["path"], .string("/v1/" + path))
                XCTAssertNil(request["headers"]?.object?["Idempotency-Key"])
            }
        }
    }

    func testFailureDoesNotRetryOrExposeResponseBody() async throws {
        try await withPeer(status: 503, response: "fixture-private-diagnostic") { client, calls in
            do {
                _ = try await client.request(.object(["method": .string("send")]), operationID: UUID())
                XCTFail("Expected failure")
            } catch let error as BBCError {
                XCTAssertTrue(error.localizedDescription.contains("503"))
                XCTAssertFalse(error.localizedDescription.contains("fixture-private-diagnostic"))
            }
            XCTAssertEqual(try calls().count, 1)
        }
    }

    func testRedirectDoesNotForwardCredentialsOrReplayMutation() async throws {
        try await withPeer(status: 307, redirect: true) { client, calls in
            do {
                _ = try await client.request(.object(["method": .string("send")]), operationID: UUID())
                XCTFail("Expected redirect rejection")
            } catch is BBCError { }
            XCTAssertEqual(try calls().count, 1)
        }
    }

    func testMalformedResponseDoesNotRetry() async throws {
        try await withPeer(response: "not JSON") { client, calls in
            do {
                _ = try await client.request(.object(["method": .string("send")]), operationID: UUID())
                XCTFail("Expected decoding failure")
            } catch is DecodingError { }
            XCTAssertEqual(try calls().count, 1)
        }
    }

    func testOversizedResponseIsRejectedWithoutRetry() async throws {
        try await withPeer(response: String(repeating: "x", count: 2_000_001)) { client, calls in
            do {
                _ = try await client.request(.object(["method": .string("send")]), operationID: UUID())
                XCTFail("Expected response bound")
            } catch let error as BBCError {
                XCTAssertTrue(error.localizedDescription.contains("reconcile"))
            }
            XCTAssertEqual(try calls().count, 1)
        }
    }

    func testUploadSendsExactBytesAndFilename() async throws {
        try await withPeer(status: 201, response: "{\"media_id\":\"fixture-media\"}") { client, calls in
            let result = try await client.uploadMedia(Data("fixture bytes".utf8), filename: "fixture.png")
            XCTAssertEqual(result.object?["media_id"], .string("fixture-media"))
            let request = try XCTUnwrap(calls().first)
            XCTAssertEqual(request["path"], .string("/v1/media/upload"))
            XCTAssertEqual(request["body"], .string("fixture bytes"))
            XCTAssertEqual(request["headers"]?.object?["X-BBC-Filename"], .string("fixture.png"))
            XCTAssertEqual(request["headers"]?.object?["Content-Type"], .string("application/octet-stream"))
        }
    }

    func testInvalidUploadsFailBeforeDispatch() async throws {
        try await withPeer { client, calls in
            for (data, filename) in [(Data(), "empty.png"), (Data([1]), "bad\r\nheader"), (Data([1]), String(repeating: "x", count: 101))] {
                do { _ = try await client.uploadMedia(data, filename: filename); XCTFail("Expected invalid upload") }
                catch let error as BBCError {
                    guard case .invalid = error else { return XCTFail("Unexpected error: \(error)") }
                }
            }
            XCTAssertTrue(try calls().isEmpty)
        }
    }

    func testUnsafeEndpointsAndUnknownMethodsFailBeforeNetworking() async throws {
        for endpoint in ["file:///tmp/fixture", "https://user:secret@example.invalid", "https://example.invalid?query=1", "https://example.invalid#fragment"] {
            do {
                _ = try await BBCHTTPClient(baseURL: URL(string: endpoint)!, apiKey: "fixture").request(.object(["method": .string("status")]))
                XCTFail("Expected invalid endpoint")
            } catch let error as BBCError {
                guard case .invalid = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        let client = BBCHTTPClient(baseURL: URL(string: "http://127.0.0.1:1")!, apiKey: "fixture")
        for payload: BBCJSONValue in [.null, .object(["method": .string("unsupported")])] {
            do { _ = try await client.request(payload); XCTFail("Expected invalid request") }
            catch let error as BBCError {
                guard case .invalid = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }
}
