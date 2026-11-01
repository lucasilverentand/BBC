import Foundation
import CryptoKit
import BBCClient

@MainActor final class APIRouter {
    let keys: APIKeyStore
    private let execute: @MainActor (BBCJSONValue) async throws -> BBCJSONValue
    private var uploading = false
    private var typing: [UUID: Task<Void, Never>] = [:]
    private let webhooks: WebhookService?
    private let schedules: LocalScheduleService?
    private let mode: OperatingMode
    init(keys: APIKeyStore, webhooks: WebhookService? = nil, schedules: LocalScheduleService? = nil,
         mode: OperatingMode = .full,
         execute: @escaping @MainActor (BBCJSONValue) async throws -> BBCJSONValue) {
        self.keys = keys; self.webhooks = webhooks; self.schedules = schedules; self.mode = mode; self.execute = execute
    }
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
            if method == "GET", path == "/v1/status" {
                let result = try await execute(.object(["method": .string("status")]))
                guard var fields = result.object else { throw ActionFailure.unavailable }
                guard let access = keys.keys.first(where:{ $0.id == keyID })?.access else { return .init(status:401,value:.object(["error":.string("unauthorized")])) }
                var methods: [BBCJSONValue] = []
                if case .array(let values) = fields["methods"] { methods = values }
                if webhooks != nil { methods += ["webhooks.register","webhooks.list","webhooks.remove"].map(BBCJSONValue.string) }
                if schedules != nil { methods += ["schedule.create","schedule.update","schedule.cancel","schedule.get","schedule.list"].map(BBCJSONValue.string) }
                fields["methods"] = .array(methods.filter { $0.string.map { mode.allows(method:$0) && keys.allows(keyID,method:$0) } == true })
                fields["key_access"] = .string(access.rawValue)
                fields["operating_mode"] = .string(mode.rawValue)
                if mode == .readOnly || !keys.allows(keyID,method:"send") {
                    fields["native_bridge_ready"] = .bool(false)
                    fields["native_bridge"] = .object(["ready":.bool(false),"reason":.string("read_only_mode"),"capabilities":.array([])])
                }
                return .init(status:200,value:.object(fields))
            }
            guard method == "POST" else { return .init(status: 404, value: .object(["error": .string("not_found")])) }
            if path == "/v1/media/upload" {
                guard mode == .full else { return readOnlyDenied }
                guard keys.allows(keyID,method:"send") else { return keyDenied }
                guard !uploading, let filename = headers["x-bbc-filename"] else { throw ActionFailure.invalid }
                uploading = true; defer { uploading = false }
                let store = try MediaStore(directory: keys.directory.appendingPathComponent("media"))
                return .init(status: 201, value: try await store.create(body, filename: filename).packet)
            }
            let request = try JSONDecoder().decode(BBCJSONValue.self, from: body)
            let endpointMethods = [
                "/v1/messages":"send", "/v1/messages/after":"messages.after", "/v1/messages/status":"messages.status",
                "/v1/messages/search":"messages.search", "/v1/messages/edit":"messages.edit", "/v1/messages/unsend":"messages.unsend",
                "/v1/messages/multipart":"messages.multipart", "/v1/availability":"availability",
                "/v1/groups/create":"groups.create", "/v1/groups/add":"groups.add", "/v1/groups/remove":"groups.remove",
                "/v1/groups/name":"groups.name", "/v1/groups/photo":"groups.photo", "/v1/groups/leave":"groups.leave",
                "/v1/replies":"reply", "/v1/links":"link", "/v1/media/download":"media.download", "/v1/tapbacks":"tapback",
                "/v1/read":"read", "/v1/read/status":"read.status", "/v1/typing/start":"typing.start", "/v1/typing/stop":"typing.stop",
                "/v1/media/visual":"media.visual", "/v1/media/transcribe":"media.transcribe",
                "/v1/webhooks/register":"webhooks.register", "/v1/webhooks/list":"webhooks.list", "/v1/webhooks/remove":"webhooks.remove",
                "/v1/schedules/create":"schedule.create", "/v1/schedules/update":"schedule.update", "/v1/schedules/cancel":"schedule.cancel",
                "/v1/schedules/get":"schedule.get", "/v1/schedules/list":"schedule.list"
            ]
            guard let operationMethod = endpointMethods[path], var params = request.object else { return .init(status: 404, value: .object(["error": .string("not_found")])) }
            guard mode.allows(method:operationMethod) else { return readOnlyDenied }
            guard keys.allows(keyID,method:operationMethod) else { return keyDenied }
            let observational = ["messages.after","messages.status","messages.search","availability","media.download","read.status","media.visual","media.transcribe","webhooks.list","schedule.get","schedule.list"].contains(operationMethod)
            if operationMethod == "send" {
                params["service"] = .string("imessage"); params["allow_sms_fallback"] = .bool(false)
            }
            let payload: BBCJSONValue = .object(["method": .string(operationMethod), "params": .object(params)])
            func perform(_ operationID: UUID? = nil) async throws -> BBCJSONValue {
                if operationMethod.hasPrefix("webhooks.") {
                    guard let webhooks else { throw ActionFailure.unavailable }
                    return try await webhooks.handle(method:operationMethod,params:params,keyID:keyID)
                }
                if operationMethod.hasPrefix("schedule.") {
                    guard let schedules else { throw ActionFailure.unavailable }
                    return try schedules.handle(method:operationMethod,params:params,keyID:keyID,operationID:operationID)
                }
                return try await execute(payload)
            }
            if observational { return .init(status: 200, value: try await perform()) }
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
                do { result = try await perform(operationID) }
                catch { result = .object(["ok": .bool(false), "uncertain": .bool(true), "error": .string("reconcile_before_retrying")]) }
            }
            // Revocation stops new work; an already dispatched effect retains its receipt.
            try persist(.init(fingerprint: fingerprint, result: result))
            return .init(status: 200, value: result)
        } catch { return .init(status: 400, value: .object(["error": .string("invalid_or_unavailable_request")])) }
    }
    func keysChanged() { for task in typing.values { task.cancel() }; typing.removeAll() }
    private var readOnlyDenied: Response { .init(status:403,value:.object(["ok":.bool(false),"uncertain":.bool(false),"error":.string("readonly_mode")])) }
    private var keyDenied: Response { .init(status:403,value:.object(["ok":.bool(false),"uncertain":.bool(false),"error":.string("key_readonly")])) }
    func startServices() { webhooks?.start(); if mode == .full { schedules?.start() } }
    func stop() { keysChanged(); webhooks?.stop(); schedules?.stop() }
}
