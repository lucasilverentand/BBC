import Foundation
import XCTest
@testable import BBCClient
@testable import BBCMessagesActions

/// Suspends a fake native call until the test releases it; cancellation resumes it with an error.
@MainActor private final class Gate {
    var calls = 0
    private var waiter: CheckedContinuation<BBCJSONValue, Error>?
    var isWaiting: Bool { waiter != nil }
    func enter() async throws -> BBCJSONValue {
        calls += 1
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                if Task.isCancelled { $0.resume(throwing: CancellationError()) } else { waiter = $0 }
            }
        } onCancel: { Task { @MainActor in self.release(throwing: CancellationError()) } }
    }
    func release(_ value: BBCJSONValue) { waiter?.resume(returning: value); waiter = nil }
    func release(throwing error: Error) { waiter?.resume(throwing: error); waiter = nil }
}

private let receipt: BBCJSONValue = .object(["ok": .bool(true), "guid": .string("fixture-receipt")])
private let body = Data(#"{"to":"fixture@example.test","text":"fixture"}"#.utf8)

private func headers(_ secret: String, _ id: UUID? = nil) -> [String: String] {
    var value = ["authorization": "Bearer " + secret]
    if let id { value["idempotency-key"] = id.uuidString }
    return value
}
@MainActor private func file(_ directory: URL, _ keys: APIKeyStore, _ id: UUID, key: Int = 0) -> URL {
    directory.appendingPathComponent("operation-\(keys.keys[key].id)-\(id).json")
}
@MainActor private func readRecord(_ url: URL) throws -> APIRouter.Operation { try JSONDecoder().decode(APIRouter.Operation.self, from: Data(contentsOf: url)) }
@MainActor private func until(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for \(what)")
            throw ActionFailure.unavailable
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor private func startTyping(_ router: APIRouter, _ secret: String, _ id: UUID, _ typing: UUID) async -> APIRouter.Response {
    await router.handle(method: "POST", path: "/v1/typing/start", headers: headers(secret, id), body: Data(#"{"typing_id":"\#(typing)","chat_guid":"fixture"}"#.utf8))
}


@MainActor final class APIRouterLifecycleTests: XCTestCase {
    private func fixture(_ run: (APIKeyStore, String, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bbc-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path); try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory), secret = try keys.create(name: "Fixture")
        try await run(keys, secret, directory)
    }
    // MARK: Parity

    func testSDKAndServerRouteTablesAndObservationalSetsAgree() {
        var server: [String: String] = [:]   // method -> relative route
        for (path, method) in APIRouter.routeMethods { server[method] = String(path.dropFirst("/v1/".count)) }
        var sdk = BBCHTTPClient.routes
        XCTAssertEqual(sdk.removeValue(forKey: "status"), "status")   // GET status is handled outside the POST table
        XCTAssertNil(server["status"])
        XCTAssertEqual(server, sdk)
        XCTAssertEqual(APIRouter.routeMethods.count, server.count, "Server paths must map to unique methods")
        XCTAssertFalse(APIRouter.observationalMethods.contains("status"))
        XCTAssertEqual(BBCHTTPClient.observationalMethods.subtracting(["status"]), APIRouter.observationalMethods)
        XCTAssertTrue(BBCHTTPClient.observationalMethods.contains("status"))
        XCTAssertTrue(APIRouter.observationalMethods.isSubset(of: Set(server.keys)))
    }

    // MARK: Idempotency

    func testInFlightSameKeyExecutesOnceAndOtherKeyIsIsolated() async throws {
        try await fixture { keys, secret, directory in
            let gate = Gate()
            let router = APIRouter(keys: keys) { _ in try await gate.enter() }
            let id = UUID()
            let first = Task { await router.handle(method: "POST", path: "/v1/messages", headers: headers(secret, id), body: body) }
            try await until("native call") { gate.isWaiting }
            let concurrent = await router.handle(method: "POST", path: "/v1/messages", headers: headers(secret, id), body: body)
            XCTAssertEqual(concurrent.status, 409); XCTAssertEqual(concurrent.value.object?["uncertain"]?.bool, true)
            let changed = await router.handle(method: "POST", path: "/v1/messages", headers: headers(secret, id), body: Data(#"{"text":"other"}"#.utf8))
            XCTAssertEqual(changed.value.object?["error"]?.string, "idempotency_conflict")
            XCTAssertEqual(gate.calls, 1)
            gate.release(receipt)
            let done = await first.value
            XCTAssertEqual(done.status, 200); XCTAssertEqual(done.value, receipt)
            XCTAssertEqual(try readRecord(file(directory, keys, id)).result, receipt)
            // The same UUID under another key is a different operation; lookup is key-scoped.
            let second = try keys.create(name: "Second")
            let other = Task { await router.handle(method: "POST", path: "/v1/messages", headers: headers(second, id), body: body) }
            try await until("second native call") { gate.isWaiting }
            let lookup = await router.handle(method: "GET", path: "/v1/operations/\(id)", headers: headers(second), body: Data())
            XCTAssertEqual(lookup.value.object?["error"]?.string, "reconcile_before_retrying")
            gate.release(receipt); _ = await other.value
            XCTAssertEqual(gate.calls, 2)
            let own = await router.handle(method: "GET", path: "/v1/operations/\(id)", headers: headers(secret), body: Data())
            XCTAssertEqual(own.status, 200); XCTAssertEqual(own.value, receipt)
            let unknown = await router.handle(method: "GET", path: "/v1/operations/\(UUID())", headers: headers(secret), body: Data())
            XCTAssertEqual(unknown.status, 404)
        }
    }

    func testIntentWriteFailureExecutesNothing() async throws {
        try await fixture { keys, secret, directory in
            try XCTSkipIf(geteuid() == 0, "Permissions are not enforced for root")
            var calls = 0
            let router = APIRouter(keys: keys) { _ in calls += 1; return .null }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            let id = UUID()
            let response = await router.handle(method: "POST", path: "/v1/messages", headers: headers(secret, id), body: body)
            XCTAssertEqual(response.status, 400); XCTAssertEqual(calls, 0)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file(directory, keys, id).path))
        }
    }

    // MARK: Reopen

    func testCompletedAndUnresolvedRecordsSurviveFreshStoreAndRouter() async throws {
        try await fixture { keys, secret, directory in
            var calls = 0
            let done = UUID(), pending = UUID()
            let router = APIRouter(keys: keys) { _ in calls += 1; return receipt }
            _ = await router.handle(method: "POST", path: "/v1/messages", headers: headers(secret, done), body: body)
            // Unresolved: intent only, as left by a crash between intent and receipt.
            var payload = try JSONDecoder().decode(BBCJSONValue.self, from: body).object ?? [:]
            payload["service"] = .string("imessage"); payload["allow_sms_fallback"] = .bool(false)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let wire: BBCJSONValue = .object(["method": .string("send"), "params": .object(payload)])
            let digest = APIKeyStore.digest(String(decoding: try encoder.encode(wire), as: UTF8.self))
            try encoder.encode(APIRouter.Operation(fingerprint: digest)).write(to: file(directory, keys, pending))

            let reopenedKeys = try APIKeyStore(directory: directory)
            let reopened = APIRouter(keys: reopenedKeys) { _ in calls += 1; return .null }
            let replay = await reopened.handle(method: "POST", path: "/v1/messages", headers: headers(secret, done), body: body)
            XCTAssertEqual(replay.status, 200); XCTAssertEqual(replay.value, receipt)
            let unresolved = await reopened.handle(method: "POST", path: "/v1/messages", headers: headers(secret, pending), body: body)
            XCTAssertEqual(unresolved.status, 409); XCTAssertEqual(unresolved.value.object?["uncertain"]?.bool, true)
            let lookup = await reopened.handle(method: "GET", path: "/v1/operations/\(pending)", headers: headers(secret), body: Data())
            XCTAssertEqual(lookup.value.object?["error"]?.string, "reconcile_before_retrying")
            XCTAssertEqual(calls, 1)
        }
    }

    func testCorruptAndTruncatedRecordsFailClosed() async throws {
        try await fixture { keys, secret, directory in
            var calls = 0
            let router = APIRouter(keys: keys) { _ in calls += 1; return .null }
            let samples: [Data] = [Data(), Data("{".utf8), Data(#"{"fingerprint":"#.utf8), Data("not json".utf8), Data(#"{"result":{}}"#.utf8)]
            for sample in samples {
                let id = UUID()
                try sample.write(to: file(directory, keys, id))
                let post = await router.handle(method: "POST", path: "/v1/messages", headers: headers(secret, id), body: body)
                XCTAssertEqual(post.status, 400)
                let get = await router.handle(method: "GET", path: "/v1/operations/\(id)", headers: headers(secret), body: Data())
                XCTAssertEqual(get.status, 400)
            }
            XCTAssertEqual(calls, 0)
        }
    }

    func testStoredPermissionsArePrivate() async throws {
        try await fixture { keys, secret, directory in
            let router = APIRouter(keys: keys) { _ in receipt }
            let id = UUID()
            _ = await router.handle(method: "POST", path: "/v1/messages", headers: headers(secret, id), body: body)
            func mode(_ url: URL) throws -> Int { ((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
            XCTAssertEqual(try mode(file(directory, keys, id)), 0o600)
            XCTAssertEqual(try mode(directory.appendingPathComponent("keys.json")), 0o600)
            XCTAssertEqual(try mode(directory), 0o700)
        }
    }

    func testFinalReceiptWriteFailureBlocksReplayAfterReopen() async throws {
        try await fixture { keys, secret, directory in
            let displaced = directory.appendingPathExtension("displaced")
            defer { if FileManager.default.fileExists(atPath: displaced.path) { try? FileManager.default.moveItem(at: displaced, to: directory) } }
            var calls = 0
            let router = APIRouter(keys: keys) { _ in
                calls += 1
                try FileManager.default.moveItem(at: directory, to: displaced)
                return receipt
            }
            let id = UUID()
            let first = await router.handle(method: "POST", path: "/v1/messages", headers: headers(secret, id), body: body)
            XCTAssertEqual(first.status, 200); XCTAssertEqual(first.value, receipt)
            try FileManager.default.moveItem(at: displaced, to: directory)
            let reopened = APIRouter(keys: try APIKeyStore(directory: directory)) { _ in calls += 1; return .null }
            let retry = await reopened.handle(method: "POST", path: "/v1/messages", headers: headers(secret, id), body: body)
            XCTAssertEqual(retry.status, 409); XCTAssertEqual(retry.value.object?["uncertain"]?.bool, true)
            XCTAssertNil(try readRecord(file(directory, keys, id)).result)
            XCTAssertEqual(calls, 1)
        }
    }

    // MARK: Typing

    func testTypingAcceptedThenCompletionWritesFinalReceiptOnce() async throws {
        try await fixture { keys, secret, directory in
            let gate = Gate(), id = UUID(), typing = UUID()
            let router = APIRouter(keys: keys) { _ in try await gate.enter() }
            let accepted = await startTyping(router, secret, id, typing)
            XCTAssertEqual(accepted.value.object?["native_confirmation"]?.string, "pending")
            try await until("native typing call") { gate.isWaiting }
            XCTAssertEqual(try readRecord(file(directory, keys, id)).result?.object?["native_confirmation"]?.string, "pending")
            gate.release(receipt)
            try await until("final receipt") { (try? readRecord(file(directory, keys, id)).result) == receipt }
            let replay = await startTyping(APIRouter(keys: try APIKeyStore(directory: directory)) { _ in XCTFail("replay"); return .null }, secret, id, typing)
            XCTAssertEqual(replay.status, 200); XCTAssertEqual(replay.value, receipt)
            XCTAssertEqual(gate.calls, 1)
        }
    }

    func testImmediateTypingCompletionIsNotOverwrittenByProvisionalAccept() async throws {
        try await fixture { keys, secret, directory in
            var calls = 0
            let router = APIRouter(keys: keys) { _ in calls += 1; return receipt }
            let id = UUID()
            _ = await startTyping(router, secret, id, UUID())
            try await until("final receipt") { (try? readRecord(file(directory, keys, id)).result) == receipt }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(try readRecord(file(directory, keys, id)).result, receipt)
            XCTAssertEqual(calls, 1)
        }
    }

    func testTypingStopAndKeyChangeCancelWithOneNativeCall() async throws {
        try await fixture { keys, secret, directory in
            let notConfirmed: BBCJSONValue = .object(["ok": .bool(false), "uncertain": .bool(true), "error": .string("typing_not_confirmed")])
            for viaStop in [true, false] {
                let gate = Gate(), id = UUID(), typing = UUID()
                let router = APIRouter(keys: keys) { _ in try await gate.enter() }
                _ = await startTyping(router, secret, id, typing)
                try await until("native typing call") { gate.isWaiting }
                if viaStop {
                    let stop = await router.handle(method: "POST", path: "/v1/typing/stop", headers: headers(secret, UUID()), body: Data(#"{"typing_id":"\#(typing)"}"#.utf8))
                    XCTAssertEqual(stop.value.object?["cleanup"]?.string, "requested")
                } else { router.keysChanged() }
                try await until("cancelled receipt") { (try? readRecord(file(directory, keys, id)).result) == notConfirmed }
                XCTAssertEqual(gate.calls, 1)
                let again = await startTyping(router, secret, id, typing)
                XCTAssertEqual(again.value, notConfirmed); XCTAssertEqual(gate.calls, 1)
            }
        }
    }
}
