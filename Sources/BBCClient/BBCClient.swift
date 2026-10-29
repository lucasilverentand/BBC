import Foundation
import BBCSQLite
#if os(macOS)
import Darwin

/// A local stdio adapter. It never changes SIP, injects a helper, or opens a port.
public struct BBCClient: Sendable {
    public let executable: URL
    public let database: URL
    public let nativeExecutable: URL
    public let nativeEnvironment: [String: String]
    public init(executable: URL? = nil, database: URL? = nil, nativeExecutable: URL? = nil, nativeEnvironment: [String: String] = [:]) {
        self.nativeExecutable = nativeExecutable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BlueBubbleClub")
        self.nativeEnvironment = nativeEnvironment
        self.executable = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BlueBubbleClub")
        self.database = database ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
    }
    public func request(_ payload: BBCJSONValue) async throws -> BBCJSONValue {
        if payload.object?["method"]?.string == "typing.start" {
            let helper = nativeExecutable
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw BBCError.unavailable("Native typing is unavailable.") }
            let input = try JSONEncoder().encode(payload) + Data([10]), child = BoundedMessagesProcess()
            let output = try await withTaskCancellationHandler {
                try await Task.detached { try child.run(executable:helper,arguments:["--native-actions", "--typing-session"],input:input,timeoutSeconds:35,typingSession:true, environment:nativeEnvironment) }.value
            } onCancel: { child.cancelTyping() }
            return try JSONDecoder().decode(BBCJSONValue.self,from:output)
        }

        if payload.object?["method"]?.string == "send", payload.object?["params"]?.object?["reply_to"] != nil {
            var request = payload.object!; request["method"] = .string("reply"); return try await nativeRequest(.object(request))
        }
        if ["reply", "tapback", "read", "read.status", "media.transcribe", "media.visual"].contains(payload.object?["method"]?.string ?? "") {
            return try await nativeRequest(payload)
        }
        let result = try await legacyRequest(payload)
        guard payload.object?["method"]?.string == "status", var status = result.object else { return result }
        // The old injected-helper reaction is never a substitute for this adapter.
        let oldMethods: [BBCJSONValue]
        if case .array(let values) = status["methods"] { oldMethods = values } else { oldMethods = [] }
        var methods = oldMethods.compactMap(\.string).filter { !["tapback", "read", "media.transcribe", "media.visual", "reply", "typing"].contains($0) }
        if let native = try? await nativeRequest(.object(["method": .string("status")])),
           case .array(let ready) = native.object?["methods"] {
            methods += ready.compactMap(\.string).filter { ["tapback", "read", "media.transcribe", "media.visual", "reply", "typing"].contains($0) }
            status["native_accessibility"] = native.object?["accessibility"]
            status["native_automation"] = native.object?["automation"]
        }
        status["methods"] = .array(Array(Set(methods)).sorted().map(BBCJSONValue.string))
        return .object(status)
    }
    private func nativeRequest(_ payload: BBCJSONValue) async throws -> BBCJSONValue {
        let helper = nativeExecutable
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw BBCError.unavailable("Native Messages actions are not installed.") }
        let input = try JSONEncoder().encode(payload)
        return try await Task.detached {
            let output = try BoundedMessagesProcess().run(executable: helper, arguments: ["--native-actions"], input: input,
                                                         timeoutSeconds: ["media.transcribe", "media.visual"].contains(payload.object?["method"]?.string ?? "") ? 90 : 25, environment: nativeEnvironment)
            return try JSONDecoder().decode(BBCJSONValue.self, from: output)
        }.value
    }
    private func legacyRequest(_ payload: BBCJSONValue) async throws -> BBCJSONValue {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              let method = payload.object?["method"]?.string else {
            throw BBCError.unavailable("The Blue Bubble Club app executable is unavailable.")
        }
        let id = UUID().uuidString
        let record: BBCJSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": payload.object?["params"] ?? .object([:])])
        let input = try JSONEncoder().encode(record) + Data([10])
        let executable = self.executable, database = self.database
        let result = try await Task.detached {
            let child = BoundedMessagesProcess()
            let output = try child.run(executable: executable, arguments: ["--rpc", "--db", database.path], input: input)
            let records = output.split(separator: 10).compactMap { try? JSONDecoder().decode(BBCJSONValue.self, from: Data($0)) }
            guard let reply = records.first(where: { $0.object?["id"]?.string == id }), reply.object?["jsonrpc"]?.string == "2.0" else {
                throw BBCError.unavailable("Messages returned no matching receipt. A dispatched mutation may have completed; do not repeat it.")
            }
            if let error = reply.object?["error"]?.object {
                // Do not display raw subprocess/provider diagnostics or message data.
                let rawDisposition = error["data"]?.object?["disposition"]?.string ?? "unknown"
                let disposition = ["not-dispatched", "uncertain", "rejected"].contains(rawDisposition) ? rawDisposition : "unknown"
                throw BBCError.unavailable("Messages operation failed (\(disposition)). Check permissions or reconcile the saved operation before retrying.")
            }
            guard let result = reply.object?["result"] else { throw BBCError.invalid("Invalid Messages receipt.") }
            return result
        }.value
        return method == "messages.after" ? try verifiedServices(in: result) : result
    }
    /// `any` is a transport-neutral chat identifier. Confirm the actual message
    /// service from the same local database before admitting it as iMessage.
    private func verifiedServices(in page: BBCJSONValue) throws -> BBCJSONValue {
        guard var object = page.object, case .array(let rows) = object["messages"],
              rows.contains(where: { row in
                  if row.object?["chat_guid"]?.string?.hasPrefix("iMessage;-;") == true { return true }
                  if row.object?["chat_guid"]?.string?.hasPrefix("any;-;") == true { return true }
                  if case .array(let attachments) = row.object?["attachments"] { return !attachments.isEmpty }
                  return false
              }) else { return page }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); throw BBCError.unavailable("Cannot verify the Messages transport.")
        }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        let query = "SELECT m.service, m.thread_originator_guid FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE m.guid=?1 AND c.guid=?2 LIMIT 2"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw BBCError.unavailable("Cannot verify the Messages transport.") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        object["messages"] = .array(try rows.map { value in
            guard var row = value.object, let chat = row["chat_guid"]?.string,
                  chat.hasPrefix("any;-;") || chat.hasPrefix("iMessage;-;") else { return value }
            if chat.hasPrefix("any;-;") { row.removeValue(forKey: "service") }
            guard let guid = row["guid"]?.string, guid.utf8.count <= 512 else { return .object(row) }
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            guard sqlite3_bind_text(statement, 1, guid, -1, transient) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, chat, -1, transient) == SQLITE_OK else { throw BBCError.unavailable("Cannot verify the Messages transport.") }
            let first = sqlite3_step(statement)
            if first == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) {
                let service = String(cString: raw)
                // The pinned reader may confuse the latest message with the reply root.
                let root = sqlite3_column_text(statement, 1).flatMap { MessageGUID.normalize(String(cString: $0)) }
                row["reply_to_guid"] = root.map(BBCJSONValue.string) ?? .null
                guard sqlite3_step(statement) == SQLITE_DONE else { throw BBCError.unavailable("Messages transport identity is ambiguous.") }
                row["service"] = .string(service)
                if service == "iMessage", case .array(let attachments) = row["attachments"], !attachments.isEmpty {
                    row["attachments"] = .array(try attachmentMetadata(db: db!, chat: chat, message: guid))
                }
            } else if first != SQLITE_DONE { throw BBCError.unavailable("Cannot verify the Messages transport.") }
            return .object(row)
        })
        return .object(object)
    }
    /// The pinned reader omits attachment GUIDs. Enrich only the exact local
    /// message/chat association with opaque IDs and bounded metadata; no paths.
    private func attachmentMetadata(db: OpaquePointer, chat: String, message: String) throws -> [BBCJSONValue] {
        let sql = """
            SELECT a.guid,a.mime_type,a.uti,a.total_bytes,a.is_sticker
            FROM attachment a JOIN message_attachment_join ma ON ma.attachment_id=a.ROWID
            JOIN message m ON m.ROWID=ma.message_id
            JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
            WHERE m.guid=?1 AND c.guid=?2 AND m.service='iMessage' ORDER BY a.ROWID LIMIT 20
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw BBCError.unavailable("Messages attachment identity metadata is unavailable.") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, message, -1, transient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, chat, -1, transient) == SQLITE_OK else { throw BBCError.unavailable("Messages attachment identity lookup failed.") }
        var result: [BBCJSONValue] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw BBCError.unavailable("Messages attachment identity lookup failed.") }
            func string(_ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
            let id = string(0), mime = string(1), uti = string(2), size = sqlite3_column_int64(statement, 3)
            guard !id.isEmpty, id.utf8.count <= 256, !id.utf8.contains(0), mime.utf8.count <= 256, uti.utf8.count <= 256,
                  size >= 0, size <= 9_007_199_254_740_991 else { throw BBCError.invalid("Messages attachment identity metadata is invalid.") }
            result.append(.object(["guid": .string(id), "mime_type": .string(mime), "uti": .string(uti),
                                   "total_bytes": .number(Double(size)), "is_sticker": .bool(sqlite3_column_int(statement, 4) != 0)]))
        }
    }
    /// Tail bootstrap reads metadata only and never imports old message contents.
    public func databasePosition() throws -> (identity: String, rowID: Int64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: database.path)
        guard let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { throw BBCError.unavailable("Cannot identify the Messages database.") }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); throw BBCError.unavailable("Allow the host app Full Disk Access in the Messages macOS login.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ROWID), 0) FROM message", -1, &statement, nil) == SQLITE_OK else { throw BBCError.unavailable("The Messages database schema is unavailable.") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw BBCError.unavailable("Cannot read the Messages database cursor.") }
        return ("\(inode):\(created.timeIntervalSince1970)", sqlite3_column_int64(statement, 0))
    }
}
final class BoundedMessagesProcess: @unchecked Sendable {
    private let process = Process()
    private let typingLock = NSLock()
    private var typingInput: FileHandle?
    private var typingCanceled = false
    func cancelTyping() {
        typingLock.lock(); typingCanceled = true; let input = typingInput; typingInput = nil; typingLock.unlock()
        try? input?.close()
    }
    func run(executable: URL, arguments: [String], input: Data, timeoutSeconds: TimeInterval = 25, typingSession: Bool = false, environment: [String: String] = [:]) throws -> Data {
        let incoming = Pipe(), outgoing = Pipe()
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, configured in configured }
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = FileHandle.nullDevice
        if typingSession {
            typingLock.lock(); let canceled = typingCanceled
            if !canceled { typingInput = incoming.fileHandleForWriting }; typingLock.unlock()
            if canceled { throw CancellationError() }
        }
        try process.run()
        let timeout = DispatchWorkItem { [self] in
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer { if typingSession { cancelTyping() }; timeout.cancel(); if process.isRunning { process.terminate() }; try? incoming.fileHandleForWriting.close(); try? outgoing.fileHandleForReading.close() }
        try incoming.fileHandleForWriting.write(contentsOf: input); if !typingSession { try incoming.fileHandleForWriting.close() }
        var output = Data()
        while let chunk = try outgoing.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard output.count + chunk.count <= 2_000_000 else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw BBCError.unavailable("Messages bridge receipt exceeded its size bound. Reconcile dispatched operations.")
            }
            output.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, output.count <= 2_000_000 else { throw BBCError.unavailable("Messages bridge stopped without a confirmed receipt; reconcile dispatched operations.") }
        return output
    }
}

#endif
