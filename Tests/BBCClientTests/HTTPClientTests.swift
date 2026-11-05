import Foundation
import XCTest
@testable import BBCClient

/// A real HTTP peer on an ephemeral loopback port. It never invokes the Mac app.
final class HTTPClientTests: XCTestCase, @unchecked Sendable {
    private struct PeerFailure: Error, CustomStringConvertible { let description: String }

    private static let peerSource = """
    import sys
    print('fixture interpreter: ' + sys.executable, flush=True)
    import base64, http.server, json, os, pathlib, socket, socketserver, traceback
    print('fixture imports ready', flush=True)
    root = pathlib.Path(sys.argv[1])
    config = json.loads((root / 'config.json').read_text())
    response = base64.b64decode(config['response_b64'])
    class Peer(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self): self.respond()
        def do_POST(self): self.respond()
        def respond(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            with (root / 'calls').open('a') as calls:
                calls.write(json.dumps({'path': self.path, 'method': self.command,
                                        'headers': {name.lower(): value for name, value in self.headers.items()},
                                        'body_b64': base64.b64encode(body).decode()}) + '\\n')
            if config['disconnect']:
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            self.send_response(config['status'])
            if config['redirect']:
                self.send_header('Location', 'http://127.0.0.1:%d/redirected' % self.server.server_port)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(response)
    class LoopbackServer(http.server.HTTPServer):
        def server_bind(self):
            # The fixture has a fixed loopback identity; no reverse DNS is needed.
            socketserver.TCPServer.server_bind(self)
            self.server_name = 'localhost'
            self.server_port = self.server_address[1]
    try:
        print('fixture binding loopback', flush=True)
        server = LoopbackServer(('127.0.0.1', 0), Peer)
        (root / 'port.tmp').write_text(str(server.server_port))
        os.replace(root / 'port.tmp', root / 'port')
        print('fixture listening', flush=True)
        server.serve_forever()
    except BaseException:
        traceback.print_exc()
        sys.exit(1)
    """

    private func stop(_ process: Process) async throws {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<500 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            for _ in 0..<500 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        }
        if process.isRunning { throw PeerFailure(description: "Fixture peer did not stop") }
    }

    private func withPeer(status: Int = 200, response: Data = Data("{\"ok\":true}".utf8), redirect: Bool = false,
                          disconnect: Bool = false,
                          run: (BBCHTTPClient, () throws -> [[String: BBCJSONValue]]) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("peer.py")
        let portFile = directory.appendingPathComponent("port")
        let callsFile = directory.appendingPathComponent("calls")
        let diagnosticsFile = directory.appendingPathComponent("diagnostics")
        try Data(Self.peerSource.utf8).write(to: script)
        try JSONSerialization.data(withJSONObject: [
            "response_b64": response.base64EncodedString(), "status": status,
            "redirect": redirect, "disconnect": disconnect,
        ]).write(to: directory.appendingPathComponent("config.json"))
        XCTAssertTrue(FileManager.default.createFile(atPath: diagnosticsFile.path, contents: nil))
        let diagnostics = try FileHandle(forWritingTo: diagnosticsFile)
        let process = Process()
        #if os(macOS)
        // Match the stdio fixtures and avoid runner-specific Python shims/site setup.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-u", script.path, directory.path]
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-u", script.path, directory.path]
        #endif
        process.standardOutput = diagnostics
        process.standardError = diagnostics
        func peerDiagnostics() -> String {
            let text = (try? String(contentsOf: diagnosticsFile, encoding: .utf8)) ?? ""
            return String(text.suffix(2000))
        }
        // Foundation reaps Process children. Blocking waitUntilExit here can deadlock
        // an async XCTest executor, so teardown polls isRunning with a bounded deadline.
        var failure: Error?
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: portFile.path), process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let port = try? String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  let portNumber = UInt16(port), portNumber != 0, let baseURL = URL(string: "http://127.0.0.1:\(portNumber)") else {
                let state = process.isRunning ? "running" : "exit \(process.terminationStatus)"
                throw PeerFailure(description: "Fixture peer did not publish a port within 5 seconds (\(state)): \(peerDiagnostics())")
            }
            let client = BBCHTTPClient(baseURL: baseURL, apiKey: "fixture-only-key")
            try await run(client) {
                guard FileManager.default.fileExists(atPath: callsFile.path) else { return [] }
                return try String(contentsOf: callsFile, encoding: .utf8).split(separator: "\n").map {
                    try JSONDecoder().decode([String: BBCJSONValue].self, from: Data($0.utf8))
                }
            }
        } catch { failure = error }
        try? diagnostics.close()
        do { try await stop(process) } catch {
            // Keep files while a peer may still be alive.
            throw failure ?? error
        }
        try? FileManager.default.removeItem(at: directory)
        if let failure { throw failure }
    }

    private func body(_ request: [String: BBCJSONValue]) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(request["body_b64"]?.string)))
    }

    func testStatusUsesAuthenticatedGETWithoutBodyOrOperationID() async throws {
        try await withPeer { client, calls in
            let result = try await client.request(.object(["method": .string("status")]))
            XCTAssertEqual(result.object?["ok"], .bool(true))
            let request = try XCTUnwrap(calls().first)
            XCTAssertEqual(request["path"], .string("/v1/status"))
            XCTAssertEqual(request["method"], .string("GET"))
            XCTAssertEqual(try body(request), Data())
            XCTAssertEqual(request["headers"]?.object?["authorization"], .string("Bearer fixture-only-key"))
            XCTAssertNil(request["headers"]?.object?["idempotency-key"])
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
            XCTAssertEqual(request["headers"]?.object?["idempotency-key"], .string(id.uuidString))
            XCTAssertEqual(try JSONDecoder().decode(BBCJSONValue.self, from: body(request)), params)
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
                XCTAssertNil(request["headers"]?.object?["idempotency-key"])
            }
        }
    }

    func testFailureDoesNotRetryOrExposeResponseBody() async throws {
        try await withPeer(status: 503, response: Data("fixture-private-diagnostic".utf8)) { client, calls in
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
        try await withPeer(response: Data("not JSON".utf8)) { client, calls in
            do {
                _ = try await client.request(.object(["method": .string("send")]), operationID: UUID())
                XCTFail("Expected decoding failure")
            } catch is DecodingError { }
            XCTAssertEqual(try calls().count, 1)
        }
    }

    func testOversizedResponseIsRejectedWithoutRetry() async throws {
        try await withPeer(response: Data(repeating: 0x78, count: 2_000_001)) { client, calls in
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
        try await withPeer(status: 201, response: Data("{\"media_id\":\"fixture-media\"}".utf8)) { client, calls in
            let bytes = Data([0x00, 0xFF, 0x0A, 0x0D, 0x80, 0x7F, 0x00, 0xC3, 0x28])
            let result = try await client.uploadMedia(bytes, filename: "fixture.png")
            XCTAssertEqual(result.object?["media_id"], .string("fixture-media"))
            let request = try XCTUnwrap(calls().first)
            XCTAssertEqual(request["path"], .string("/v1/media/upload"))
            XCTAssertEqual(try body(request), bytes)
            XCTAssertEqual(request["headers"]?.object?["x-bbc-filename"], .string("fixture.png"))
            XCTAssertEqual(request["headers"]?.object?["content-type"], .string("application/octet-stream"))
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

    private static let routes: [(method: String, path: String, mutating: Bool)] = [
        ("status", "status", false), ("send", "messages", true), ("reply", "replies", true), ("link", "links", true),
        ("media.download", "media/download", false), ("messages.after", "messages/after", false),
        ("messages.status", "messages/status", false), ("messages.search", "messages/search", false),
        ("messages.edit", "messages/edit", true), ("messages.unsend", "messages/unsend", true),
        ("messages.multipart", "messages/multipart", true), ("availability", "availability", false),
        ("groups.create", "groups/create", true), ("groups.add", "groups/add", true), ("groups.remove", "groups/remove", true),
        ("groups.name", "groups/name", true), ("groups.photo", "groups/photo", true), ("groups.leave", "groups/leave", true),
        ("tapback", "tapbacks", true), ("read", "read", true), ("read.status", "read/status", false),
        ("typing.start", "typing/start", true), ("typing.stop", "typing/stop", true),
        ("media.visual", "media/visual", false), ("media.transcribe", "media/transcribe", false),
        ("webhooks.register", "webhooks/register", true), ("webhooks.list", "webhooks/list", false),
        ("webhooks.remove", "webhooks/remove", true), ("schedule.create", "schedules/create", true),
        ("schedule.update", "schedules/update", true), ("schedule.cancel", "schedules/cancel", true),
        ("schedule.get", "schedules/get", false), ("schedule.list", "schedules/list", false),
    ]

    func testFullRouteTableAndMutationClassification() async throws {
        try await withPeer { client, calls in
            var expected = 0
            for route in Self.routes {
                let id = UUID()
                // Missing operation ID: mutations fail before dispatch, reads dispatch.
                if route.mutating {
                    do {
                        _ = try await client.request(.object(["method": .string(route.method)]))
                        XCTFail("Expected operation ID requirement for \(route.method)")
                    } catch let error as BBCError {
                        guard case .invalid = error else { return XCTFail("Unexpected error: \(error)") }
                    }
                    XCTAssertEqual(try calls().count, expected, route.method)
                }
                _ = try await client.request(.object(["method": .string(route.method)]), operationID: route.mutating ? id : nil)
                expected += 1
                let requests = try calls()
                XCTAssertEqual(requests.count, expected, route.method)
                let request = try XCTUnwrap(requests.last)
                XCTAssertEqual(request["path"], .string("/v1/" + route.path), route.method)
                XCTAssertEqual(request["method"], .string(route.method == "status" ? "GET" : "POST"), route.method)
                XCTAssertEqual(request["headers"]?.object?["idempotency-key"], route.mutating ? .string(id.uuidString) : nil, route.method)
            }
        }
    }

    func testUploadSendsEveryByteValueExactly() async throws {
        try await withPeer(status: 201, response: Data("{\"media_id\":\"m\"}".utf8)) { client, calls in
            let bytes = Data((0...255).map { UInt8($0) } + [0, 0, 255])
            _ = try await client.uploadMedia(bytes, filename: "all.bin")
            XCTAssertEqual(try body(XCTUnwrap(calls().first)), bytes)
        }
    }

    func testUploadRedirectIsRefusedWithoutReplay() async throws {
        try await withPeer(status: 307, redirect: true) { client, calls in
            do { _ = try await client.uploadMedia(Data([1, 2, 3]), filename: "fixture.png"); XCTFail("Expected upload failure") }
            catch is BBCError { }
            XCTAssertEqual(try calls().count, 1)
        }
    }

    func testDisconnectAfterReadingMutationIsNotRetried() async throws {
        try await withPeer(disconnect: true) { client, calls in
            do {
                _ = try await client.request(.object(["method": .string("send"), "params": .object(["text": .string("fixture")])]), operationID: UUID())
                XCTFail("Expected transport failure")
            } catch { }
            XCTAssertEqual(try calls().count, 1)
        }
    }

    func testDisconnectAfterReadingUploadIsNotRetried() async throws {
        try await withPeer(disconnect: true) { client, calls in
            do { _ = try await client.uploadMedia(Data([9, 0, 255]), filename: "fixture.bin"); XCTFail("Expected transport failure") }
            catch { }
            XCTAssertEqual(try calls().count, 1)
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
