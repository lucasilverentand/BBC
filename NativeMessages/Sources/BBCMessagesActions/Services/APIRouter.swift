import Foundation
import CryptoKit
import BBCClient

@MainActor final class APIRouter {
    let keys: APIKeyStore
    private let execute: @MainActor (BBCJSONValue) async throws -> BBCJSONValue
    private var uploading = false
    private var typing: [UUID: Task<Void, Never>] = [:]
    init(keys: APIKeyStore, execute: @escaping @MainActor (BBCJSONValue) async throws -> BBCJSONValue) { self.keys = keys; self.execute = execute }
    struct Response { let status: Int; let value: BBCJSONValue }
    struct Operation: Codable { let fingerprint: String; var result: BBCJSONValue? }

    func handle(method: String, path: String, headers: [String: String], body: Data) async -> Response {
        guard let authorization = headers["authorization"], authorization.hasPrefix("Bearer "),
              let keyID = keys.authenticate(String(authorization.dropFirst(7))) else { return .init(status: 401, value: .object(["error": .string("unauthorized")])) }
        do {
            if method == "GET", path.hasPrefix("/v1/operations/") {
                guard let id = UUID(uuidString: String(path.dropFirst("/v1/operations/".count))) else { throw ActionFailure.invalid }
                let file = keys.directory.appendingPathComponent("operation-\(keyID)-\(id).json")
                guard FileManager.default.fileExists(atPath: file.path) else { return .init(status: 404, value: .object(["error": .string("not_found")])) }
                let record = try JSONDecoder().decode(Operation.self, from: Data(contentsOf: file))
                return .init(status: 200, value: record.result ?? .object(["ok": .bool(false), "uncertain": .bool(true), "error": .string("reconcile_before_retrying")]))
            }
            if method == "GET", path == "/v1/status" { return .init(status: 200, value: try await execute(.object(["method": .string("status")]))) }
            guard method == "POST" else { return .init(status: 404, value: .object(["error": .string("not_found")])) }
            if path == "/v1/media/upload" {
                guard !uploading, let filename = headers["x-bbc-filename"] else { throw ActionFailure.invalid }
                uploading = true; defer { uploading = false }
                let store = try MediaStore(directory: keys.directory.appendingPathComponent("media"))
                return .init(status: 201, value: try await store.create(body, filename: filename).packet)
            }
            let request = try JSONDecoder().decode(BBCJSONValue.self, from: body)
            let endpointMethods = ["/v1/ui/reset": "ui.reset", "/v1/messages": "send", "/v1/messages/after": "messages.after", "/v1/messages/status": "messages.status", "/v1/replies": "reply", "/v1/links": "link", "/v1/media/download": "media.download", "/v1/tapbacks": "tapback", "/v1/read": "read", "/v1/read/status": "read.status", "/v1/typing/start": "typing.start", "/v1/typing/stop": "typing.stop", "/v1/media/visual": "media.visual", "/v1/media/transcribe": "media.transcribe"]
            guard let operationMethod = endpointMethods[path], var params = request.object else { return .init(status: 404, value: .object(["error": .string("not_found")])) }
            let observational = ["messages.after", "messages.status", "media.download", "read.status", "media.visual", "media.transcribe"].contains(operationMethod)
            if operationMethod == "send" {
                params["service"] = .string("imessage"); params["allow_sms_fallback"] = .bool(false)
            }
            if operationMethod == "ui.reset", !params.isEmpty { throw ActionFailure.invalid }
            let payload: BBCJSONValue = .object(["method": .string(operationMethod), "params": operationMethod == "ui.reset" ? .null : .object(params)])
            if observational { return .init(status: 200, value: try await execute(payload)) }
            guard let raw = headers["idempotency-key"], let operationID = UUID(uuidString: raw) else { return .init(status: 400, value: .object(["error": .string("uuid_idempotency_key_required")])) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let fingerprint = APIKeyStore.digest(String(decoding: try encoder.encode(payload), as: UTF8.self))
            let file = keys.directory.appendingPathComponent("operation-\(keyID)-\(operationID).json")
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode(Operation.self, from: Data(contentsOf: file))
                guard saved.fingerprint == fingerprint else { return .init(status: 409, value: .object(["error": .string("idempotency_conflict")])) }
                return .init(status: saved.result == nil ? 409 : 200, value: saved.result ?? .object(["ok": .bool(false), "uncertain": .bool(true), "error": .string("reconcile_before_retrying")]))
            }
            func persist(_ record: Operation) throws {
                try encoder.encode(record).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            try persist(.init(fingerprint: fingerprint)) // Intent precedes every mutation.
            let result: BBCJSONValue
            if operationMethod == "typing.stop" {
                guard let raw = params["typing_id"]?.string, let id = UUID(uuidString: raw) else { throw ActionFailure.invalid }
                typing.removeValue(forKey: id)?.cancel()
                result = .object(["ok": .bool(true), "typing_id": .string(id.uuidString), "cleanup": .string("requested")])
            } else if operationMethod == "typing.start" {
                let id = params["typing_id"]?.string.flatMap(UUID.init(uuidString:)) ?? UUID()
                guard typing[id] == nil else { throw ActionFailure.busy }
                params["typing_id"] = .string(id.uuidString)
                let deadline = min(params["deadline"]?.numberValue ?? (Date().timeIntervalSince1970 + 30) * 1000, (Date().timeIntervalSince1970 + 30) * 1000)
                params["deadline"] = .number(deadline)
                let finalPayload: BBCJSONValue = .object(["method": .string("typing.start"), "params": .object(params)])
                typing[id] = Task { [weak self] in
                    guard let self else { return }
                    let receipt: BBCJSONValue
                    do { receipt = try await self.execute(finalPayload) }
                    catch { receipt = .object(["ok": .bool(false), "uncertain": .bool(true), "error": .string("typing_not_confirmed")]) }
                    try? persist(.init(fingerprint: fingerprint, result: receipt))
                    self.typing.removeValue(forKey: id)
                }
                result = .object(["accepted": .bool(true), "typing_id": .string(id.uuidString), "native_confirmation": .string("pending")])
            } else {
                do { result = try await execute(payload) }
                catch { result = .object(["ok": .bool(false), "uncertain": .bool(true), "error": .string("reconcile_before_retrying")]) }
            }
            // Revocation stops new work; an already dispatched effect retains its receipt.
            try persist(.init(fingerprint: fingerprint, result: result))
            return .init(status: 200, value: result)
        } catch { return .init(status: 400, value: .object(["error": .string("invalid_or_unavailable_request")])) }
    }
    func stop() { for task in typing.values { task.cancel() }; typing.removeAll() }
}
