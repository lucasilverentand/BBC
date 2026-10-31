import Foundation
import Darwin
import BBCClient

/// A local outbox owned by the running API. A dispatched send is never replayed.
@MainActor final class LocalScheduleService {
    struct Record: Codable {
        let id: UUID
        let owner: UUID
        let createdAt: Date
        let creationRequest: BBCJSONValue
        var sendAt: Date
        var message: [String: BBCJSONValue]
        var state: String
        var updatedAt: Date
        var operationID: UUID
        var result: BBCJSONValue?
    }
    private let file: URL
    private let isKeyActive: @MainActor (UUID) -> Bool
    private let execute: @MainActor (BBCJSONValue) async throws -> BBCJSONValue
    private let now: @MainActor () -> Date
    private let mediaExpiresAt: @MainActor (String) throws -> Date
    private var records: [Record]
    private var running = false
    private var generation: UInt64 = 0
    private var ticking = false
    private var timer: Task<Void, Never>?
    private var storeLock: Int32 = -1
    private static let maximumRecords = 256
    private static let maximumBytes = 8 * 1024 * 1024
    private static let terminal = Set(["sent", "failed", "uncertain", "cancelled"])

    init(directory: URL, isKeyActive: @escaping @MainActor (UUID) -> Bool,
         execute: @escaping @MainActor (BBCJSONValue) async throws -> BBCJSONValue,
         now: @escaping @MainActor () -> Date = Date.init,
         mediaExpiresAt: (@MainActor (String) throws -> Date)? = nil) throws {
        self.isKeyActive = isKeyActive; self.execute = execute; self.now = now
        self.mediaExpiresAt = mediaExpiresAt ?? { id in
            try MediaStore(directory: directory.appendingPathComponent("media")).resolve(id).0.created.addingTimeInterval(MediaStore.lifetime)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard info[.type] as? FileAttributeType == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw ActionFailure.invalid }
        // A stopped instance can still hold an in-flight send. Keep exclusive
        // store ownership for its entire lifetime so its eventual receipt cannot
        // overwrite a replacement instance's newer schedules or cancellations.
        let lock = open(directory.appendingPathComponent("schedules.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw ActionFailure.unavailable }
        var transferred = false
        defer { if !transferred { close(lock) } }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_mode & 0o077 == 0 else { throw ActionFailure.invalid }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ActionFailure.busy }
        file = directory.appendingPathComponent("schedules.json")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? input.close() }
            var details = stat()
            guard fstat(fd, &details) == 0, details.st_uid == getuid(), details.st_mode & S_IFMT == S_IFREG,
                  details.st_mode & 0o077 == 0, details.st_size <= Self.maximumBytes else { throw ActionFailure.invalid }
            let data = try input.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { throw ActionFailure.invalid }
            records = try JSONDecoder().decode([Record].self, from: data)
            guard records.count <= Self.maximumRecords,
                  Set(records.map { "\($0.owner)/\($0.id)" }).count == records.count,
                  records.allSatisfy({ Self.terminal.contains($0.state) || ["pending", "dispatching"].contains($0.state) }) else { throw ActionFailure.invalid }
        } else {
            guard errno == ENOENT else { throw ActionFailure.unavailable }
            records = []
        }
        // The previous process may have sent these. Preserve their identity and
        // uncertainty; never turn them back into queued work.
        var recovered = false
        for index in records.indices where records[index].state == "dispatching" {
            records[index].state = "uncertain"
            records[index].updatedAt = now()
            records[index].result = .object(["ok": .bool(false), "uncertain": .bool(true), "failure_code": .string("schedule_interrupted")])
            recovered = true
        }
        if recovered { try persist(records) }
        storeLock = lock; transferred = true
    }

    deinit {
        if storeLock >= 0 { flock(storeLock, LOCK_UN); close(storeLock) }
    }

    /// Polling can be disabled in tests; tick() exercises the same dispatch path.
    func start(polling: Bool = true) {
        guard !running else { return }; running = true; generation &+= 1
        guard polling else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    func stop() {
        running = false; generation &+= 1; timer?.cancel(); timer = nil
        // An already dispatched send may finish and keeps its receipt.
    }

    func handle(method: String, params: [String: BBCJSONValue], keyID: UUID, operationID: UUID? = nil) throws -> BBCJSONValue {
        guard isKeyActive(keyID) else { throw ActionFailure.invalid }
        if method == "schedule.list" {
            guard Set(params.keys).isSubset(of: ["limit"]) else { throw ActionFailure.invalid }
            let limit = params["limit"]?.numberValue ?? 100
            guard limit.isFinite, limit >= 1, limit <= 256, limit.rounded() == limit else { throw ActionFailure.invalid }
            return .object(["schedules": .array(records.filter { $0.owner == keyID }.sorted { $0.createdAt > $1.createdAt }.prefix(Int(limit)).map(packet))])
        }
        if method == "schedule.create" {
            guard let operationID, Set(params.keys) == ["send_at", "message"] else { throw ActionFailure.invalid }
            let message = try Self.message(params["message"])
            let date = try Self.date(params["send_at"])
            let canonical: BBCJSONValue = .object(["send_at": .number(date.timeIntervalSince1970), "message": .object(message)])
            if let existing = records.first(where: { $0.id == operationID && $0.owner == keyID }) {
                guard existing.creationRequest == canonical else { throw ActionFailure.invalid }
                return packet(existing)
            }
            try future(date)
            try validateMedia(message, sendAt: date)
            let clock = now()
            var changed = retained(records, at: clock)
            guard changed.count < Self.maximumRecords else { throw ActionFailure.busy }
            let record = Record(id: operationID, owner: keyID, createdAt: clock, creationRequest: canonical,
                                sendAt: date, message: message, state: "pending", updatedAt: clock, operationID: operationID)
            changed.append(record); try save(changed)
            return packet(record)
        }
        guard let raw = params["schedule_id"]?.string, let id = UUID(uuidString: raw),
              let index = records.firstIndex(where: { $0.id == id && $0.owner == keyID }) else { throw ActionFailure.invalid }
        if method == "schedule.get" {
            guard Set(params.keys) == ["schedule_id"] else { throw ActionFailure.invalid }
            return packet(records[index])
        }
        guard let operationID else { throw ActionFailure.invalid }
        if method == "schedule.cancel" {
            guard Set(params.keys) == ["schedule_id"], ["pending", "cancelled"].contains(records[index].state) else { throw ActionFailure.busy }
            var changed = records
            changed[index].state = "cancelled"; changed[index].updatedAt = now(); changed[index].operationID = operationID
            try save(changed); return packet(changed[index])
        }
        if method == "schedule.update" {
            guard Set(params.keys).isSubset(of: ["schedule_id", "send_at", "message"]), params.count > 1,
                  records[index].state == "pending" else { throw ActionFailure.busy }
            var changed = records
            if let value = params["send_at"] { changed[index].sendAt = try Self.date(value) }
            try future(changed[index].sendAt)
            if let value = params["message"] { changed[index].message = try Self.message(value) }
            try validateMedia(changed[index].message, sendAt: changed[index].sendAt)
            changed[index].updatedAt = now(); changed[index].operationID = operationID
            try save(changed); return packet(changed[index])
        }
        throw ActionFailure.invalid
    }

    func tick() async {
        guard running, !ticking else { return }
        ticking = true; defer { ticking = false }
        let activation = generation
        // Re-evaluate each record after an await so cancellation, revocation and
        // concurrent API updates cannot dispatch a stale snapshot.
        let due = records.filter { $0.state == "pending" && $0.sendAt <= now() }.map { ($0.owner, $0.id) }
        for (owner, id) in due {
            guard running, generation == activation else { return }
            guard let index = records.firstIndex(where: { $0.owner == owner && $0.id == id }),
                  records[index].state == "pending", records[index].sendAt <= now() else { continue }
            var changed = records
            changed[index].updatedAt = now()
            if !isKeyActive(owner) {
                changed[index].state = "cancelled"
                changed[index].result = .object(["ok": .bool(false), "uncertain": .bool(false), "failure_code": .string("schedule_key_revoked")])
                do { try save(changed) } catch { return }
                continue
            }
            changed[index].state = "dispatching"
            // A crash after this write is deliberately an uncertain send.
            do { try save(changed) } catch { return }
            var message = changed[index].message
            let method = message["to"] == nil ? "messages.multipart" : "send"
            if method == "send" { message["service"] = .string("imessage"); message["allow_sms_fallback"] = .bool(false) }
            let result: BBCJSONValue
            do { result = try await execute(.object(["method": .string(method), "params": .object(message)])) }
            catch { result = .object(["ok": .bool(false), "uncertain": .bool(true), "failure_code": .string("schedule_send_unconfirmed")]) }
            guard let current = records.firstIndex(where: { $0.owner == owner && $0.id == id }) else { continue }
            changed = records
            changed[current].result = result
            changed[current].state = result.object?["ok"]?.bool == true ? "sent" : (result.object?["uncertain"]?.bool == false ? "failed" : "uncertain")
            changed[current].updatedAt = now()
            // If storage fails, the durable dispatching intent remains and will
            // recover as uncertain. It is never retried in this process either.
            try? save(changed)
        }
    }

    private func future(_ date: Date) throws {
        let interval = date.timeIntervalSince(now())
        guard interval > 0, interval <= 366 * 24 * 3600 else { throw ActionFailure.invalid }
    }
    private static func date(_ value: BBCJSONValue?) throws -> Date {
        guard let value = value?.string, value.utf8.count <= 40 else { throw ActionFailure.invalid }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value), date.timeIntervalSince1970.isFinite else { throw ActionFailure.invalid }
        return date
    }
    private static func message(_ value: BBCJSONValue?) throws -> [String: BBCJSONValue] {
        guard let value = value?.object else { throw ActionFailure.invalid }
        if value["to"] != nil {
            guard Set(value.keys).isSubset(of: ["to", "text", "media_id"]),
                  let to = value["to"]?.string, to.utf8.count <= 254,
                  to.range(of: #"^(\+[1-9][0-9]{6,14}|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)$"#, options: .regularExpression) != nil,
                  (value["text"] == nil) != (value["media_id"] == nil) else { throw ActionFailure.invalid }
        } else {
            guard Set(value.keys).isSubset(of: ["chat_guid", "text", "media_ids", "effect"]),
                  let chat = value["chat_guid"]?.string, !chat.isEmpty, chat.utf8.count <= 512, !chat.utf8.contains(0),
                  chat.range(of: #"^(any|iMessage);[-+];[^\x00-\x1F]+$"#, options: .regularExpression) != nil,
                  value["text"] != nil || value["media_ids"] != nil else { throw ActionFailure.invalid }
            if let attachments = value["media_ids"] {
                guard case .array(let ids) = attachments, !ids.isEmpty, ids.count <= 8,
                      ids.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }),
                      Set(ids.compactMap(\.string)).count == ids.count else { throw ActionFailure.invalid }
            }
            if let effect = value["effect"] {
                guard let effect = effect.string, effect.utf8.count <= 160, !effect.utf8.contains(0),
                      effect.hasPrefix("com.apple.messages.effect.") || effect.hasPrefix("com.apple.MobileSMS.expressivesend.") else { throw ActionFailure.invalid }
            }
        }
        if let text = value["text"] {
            guard let text = text.string, !text.isEmpty, text.utf8.count <= 64000, !text.utf8.contains(0) else { throw ActionFailure.invalid }
        }
        if let media = value["media_id"] {
            guard let media = media.string, UUID(uuidString: media) != nil else { throw ActionFailure.invalid }
        }
        return value
    }
    private func validateMedia(_ message: [String: BBCJSONValue], sendAt: Date) throws {
        var ids = message["media_id"]?.string.map { [$0] } ?? []
        if case .array(let values) = message["media_ids"] { ids += values.compactMap(\.string) }
        for id in ids { guard sendAt < (try mediaExpiresAt(id)) else { throw ActionFailure.invalid } }
    }
    private func packet(_ record: Record) -> BBCJSONValue {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .object(["schedule_id": .string(record.id.uuidString), "send_at": .string(formatter.string(from: record.sendAt)),
                 "message": .object(record.message), "state": .string(record.state), "last_operation_id": .string(record.operationID.uuidString),
                 "result": record.result ?? .null, "dispatch": .string("while-api-running")])
    }
    private func retained(_ records: [Record], at date: Date) -> [Record] {
        records.filter { !Self.terminal.contains($0.state) || date.timeIntervalSince($0.updatedAt) < 7 * 24 * 3600 }
    }
    private func save(_ changed: [Record]) throws { try persist(changed); records = changed }
    private func persist(_ changed: [Record]) throws {
        let data = try JSONEncoder().encode(changed)
        guard data.count <= Self.maximumBytes else { throw ActionFailure.busy }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ActionFailure.unavailable }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw ActionFailure.unavailable }
    }
}
