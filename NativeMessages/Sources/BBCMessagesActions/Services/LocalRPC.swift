import Foundation
import AppKit
import SQLite3
import IMDatabase
import BBCClient

/// One-shot worker mode of the app itself. No separate helper executable.
@MainActor enum LocalRPC {
    /// Everything the worker reads from its process environment. Production
    /// defaults are the real arguments, home directory and confirmation timing.
    struct Environment {
        var arguments: [String] = CommandLine.arguments
        var mode: OperatingMode = .current
        var databaseURL: URL?
        var supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BBCMessagesActions")
        var mediaDirectory: URL = MediaStore.defaultDirectory
        var handoffDirectory: URL = MediaStore.handoffDirectory
        var confirmationTimeout: TimeInterval = 8
        var pollInterval: TimeInterval = 0.1
        var resolvedDatabaseURL: URL {
            if let databaseURL { return databaseURL }
            if let index = arguments.firstIndex(of: "--db"), arguments.indices.contains(index + 1) { return URL(fileURLWithPath: arguments[index + 1]) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        }
    }
    /// Thrown by an executor that could not start the script at all.
    struct ScriptNotStarted: Error {}
    /// Startup, permission and script actions; replaceable in tests.
    struct Actions {
        var ensureRunning: () async throws -> pid_t
        var automationStatus: (pid_t?) -> OSStatus
        /// Runs AppleScript source. Throws ScriptNotStarted if nothing ran, any other error after entry.
        var execute: (String) throws -> Void
        @MainActor static var live: Actions { Actions(
            ensureRunning: { try await NativeMessagesStartup.ensureRunning() },
            automationStatus: { NativeMessagesStartup.automationStatus(pid: $0) },
            execute: { source in
                guard let script = NSAppleScript(source: source) else { throw ScriptNotStarted() }
                var error: NSDictionary?
                _ = script.executeAndReturnError(&error)
                guard error == nil else { throw ActionFailure.uncertain }
            }) }
    }
    /// Set immediately before the script executor is invoked.
    private final class Attempt { var dispatched = false }

    static func run() async {
        var input = Data()
        do {
            while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
                guard input.count + chunk.count <= 65536 else { throw ActionFailure.invalid }; input.append(chunk)
            }
        } catch { emit(failure(id: .null, disposition: "not-dispatched")); return }
        emit(await respond(to: input, environment: Environment(), actions: .live))
    }
    private static func failure(id: BBCJSONValue, disposition: String) -> BBCJSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
            "code": .number(-32000), "message": .string("Local operation failed; reconcile before retrying."),
            "data": .object(["disposition": .string(disposition)])])])
    }
    /// Request in, JSON-RPC response out. No process I/O.
    static func respond(to input: Data, environment: Environment, actions: Actions) async -> BBCJSONValue {
        var id: BBCJSONValue = .null
        let attempt = Attempt()
        do {
            let request = try JSONDecoder().decode(BBCJSONValue.self, from: input)
            id = request.object?["id"] ?? .null
            guard let method = request.object?["method"]?.string else { throw ActionFailure.invalid }
            guard environment.mode.allows(method:method) else {
                return .object(["jsonrpc":.string("2.0"),"id":id,"error":.object([
                    "code":.number(-32003),"message":.string("Read-only mode blocks this operation."),
                    "data":.object(["disposition":.string("rejected")])])])
            }
            let parameters = request.object?["params"]?.object ?? [:]
            let db = try MessagesDatabase(url: environment.resolvedDatabaseURL)
            let result: BBCJSONValue
            switch method {
            case "status":
                _ = try db.maximumRowID()
                var methods = ["messages.after", "messages.status", "messages.search", "media.download"]
                if environment.mode == .full, actions.automationStatus(nil) == noErr { methods.append("send") }
                result = .object(["version": .string("bbc-1"), "methods": .array(methods.map(BBCJSONValue.string))])
            case "messages.after": result = try db.page(parameters)
            case "messages.search": result = try db.search(parameters)
            case "messages.status": result = try db.messageStatus(parameters)
            case "media.download": result = try db.download(parameters)
            case "send": result = try await send(parameters, database: db, environment: environment, actions: actions, attempt: attempt)
            default: throw ActionFailure.invalid
            }
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        } catch {
            return failure(id: id, disposition: attempt.dispatched ? "uncertain" : "not-dispatched")
        }
    }
    /// The attempt is already recorded; only an executor that never started the script clears it.
    private static func run(_ actions: Actions, _ source: String, _ attempt: Attempt) throws {
        do { try actions.execute(source) } catch is ScriptNotStarted { attempt.dispatched = false; throw ActionFailure.invalid }
    }
    private static func emit(_ value: BBCJSONValue) {
        if let data = try? JSONEncoder().encode(value) { try? FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
    }
    private static func send(_ p: [String: BBCJSONValue], database: MessagesDatabase, environment: Environment, actions: Actions, attempt: Attempt) async throws -> BBCJSONValue {
        guard getuid() != 0, getuid() == geteuid(), p["service"]?.string == "imessage",
              p["allow_sms_fallback"]?.bool != true,
              let to = p["to"]?.string, to.utf8.count <= 254,
              to.range(of: #"^(\+[1-9][0-9]{6,14}|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)$"#, options: .regularExpression) != nil,
              !to.utf8.contains(0) else { throw ActionFailure.invalid }
        let text = p["text"]?.string
        let media = try p["media_id"]?.string.map { try MediaStore(directory: environment.mediaDirectory).resolve($0) }
        guard (text == nil) != (media == nil) else { throw ActionFailure.invalid }
        if let text { guard !text.isEmpty, text.utf8.count <= 64000, !text.utf8.contains(0) else { throw ActionFailure.invalid } }
        let directory = environment.supportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent("automation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ActionFailure.unavailable }; defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ActionFailure.busy }; defer { flock(lock, LOCK_UN) }
        let pid = try await actions.ensureRunning()
        guard actions.automationStatus(pid) == noErr else { throw ActionFailure.unavailable }
        let before = try database.maximumRowID()
        if let media {
            let file = try MediaStore.stageHandoff(upload: media.0, source: media.1, directory: environment.handoffDirectory)
            attempt.dispatched = true
            try run(actions, MessageSendScript.file(to: to, file: file), attempt)
        } else {
            attempt.dispatched = true
            try run(actions, MessageSendScript.text(to: to, text: text!), attempt)
        }
        let deadline = Date().addingTimeInterval(environment.confirmationTimeout)
        repeat {
            if let media {
                if let sent = try database.confirmedMedia(to: to, upload: media.0, after: before) {
                    if (try? database.handoffCopied(message: sent.0, upload: media.0)) == true { try? MediaStore.removeHandoff(upload: media.0, directory: environment.handoffDirectory) }
                    return .object(["ok": .bool(true), "guid": .string(sent.0), "chat_guid": .string(sent.1),
                                    "media_id": .string(media.0.id.uuidString), "confirmation": .string("local-database")])
                }
            } else {
                let result = try database.rows("""
                    SELECT m.guid,c.guid FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
                    JOIN chat c ON c.ROWID=j.chat_id WHERE m.ROWID>CAST(?1 AS INTEGER)
                    AND m.service='iMessage' AND m.is_from_me=1 AND m.text=?2 AND c.chat_identifier=?3
                    AND m.is_sent=1 AND COALESCE(m.error,0)=0 LIMIT 2
                    """, [String(before), text!, to])
                if result.count == 1 { return .object(["ok": .bool(true), "guid": .string(result[0][0]), "chat_guid": .string(result[0][1]), "confirmation": .string("local-database")]) }
                if result.count > 1 { throw ActionFailure.uncertain }
            }
            try await Task.sleep(for: .seconds(environment.pollInterval))
        } while Date() < deadline
        throw ActionFailure.uncertain
    }
}

extension MessagesDatabase {
    func page(_ p: [String: BBCJSONValue]) throws -> BBCJSONValue {
        let after = p["since_rowid"]?.numberValue ?? 0, limit = p["limit"]?.numberValue ?? 50
        guard after.isFinite, after >= 0, after < 9_007_199_254_740_991, after.rounded() == after,
              limit.isFinite, limit >= 1, limit <= 200, limit.rounded() == limit else { throw ActionFailure.invalid }
        let chat: String
        if let value = p["chat_guid"] {
            guard let selected = value.string, !selected.isEmpty, selected.utf8.count <= 512, !selected.utf8.contains(0) else { throw ActionFailure.invalid }
            chat = selected
        } else { chat = "" }
        let emojiColumn = try optionalMessageColumn("associated_message_emoji")
        let payloadColumn = try optionalMessageColumn("payload_data", fallback: "NULL")
        let attachmentColumns = try rows("PRAGMA table_info(attachment)", []).map { $0[1] }
        let transferName = attachmentColumns.contains("transfer_name") ? "COALESCE(a.transfer_name,'')" : "''"
        let audioColumn = try optionalMessageColumn("is_audio_message", fallback: "0")
        let itemTypeColumn = try optionalMessageColumn("item_type", fallback: "NULL")
        let values = try rows("""
            SELECT m.ROWID,m.guid,c.guid,COALESCE(h.id,''),COALESCE(m.text,''),m.is_from_me,
                m.date,COALESCE(m.service,''),COALESCE(m.thread_originator_guid,''),
                COALESCE(m.associated_message_type,0),COALESCE(m.associated_message_guid,''),
                COALESCE(hex(m.attributedBody),''), \(emojiColumn), CASE WHEN length(\(payloadColumn))<=256000 THEN hex(\(payloadColumn)) ELSE '' END, \(audioColumn), \(itemTypeColumn)
            FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
            JOIN chat c ON c.ROWID=j.chat_id LEFT JOIN handle h ON h.ROWID=m.handle_id
            WHERE m.ROWID>CAST(?1 AS INTEGER) AND (?3='' OR c.guid=?3) ORDER BY m.ROWID,c.guid LIMIT ?2
            """, [String(Int64(after)), String(Int(limit)), chat])
        let messages = try values.map { row -> BBCJSONValue in
            let participants = try rows("SELECT h.id FROM handle h JOIN chat_handle_join j ON j.handle_id=h.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE c.guid=?1 ORDER BY h.id", [row[2]]).compactMap(\.first)
            var text = row[4]
            if text.isEmpty, row[11].count <= 4_000_000, let data = Data(hex: row[11]) { text = (try? AttributedBodyDecoder.plainText(from: data)) ?? "" }
            let reaction = Int(row[9]) ?? 0
            let root = normalizedGUID(row[8])
            let threadRoot = row[8].isEmpty ? normalizedGUID(row[1]) : root
            let attachmentRows = try rows("""
                SELECT a.guid,COALESCE(a.mime_type,''),COALESCE(a.uti,''),COALESCE(a.total_bytes,0),COALESCE(a.is_sticker,0), \(transferName)
                FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID JOIN message m ON m.ROWID=j.message_id WHERE m.guid=?1 ORDER BY a.ROWID LIMIT 20
                """, [row[1]])
            let attachments = p["attachments"]?.bool == true ? attachmentRows.map { a in BBCJSONValue.object(["guid": .string(a[0]), "mime_type": .string(MediaMIME.resolve(a[1], uti: a[2])), "uti": .string(a[2]), "total_bytes": .number(Double(a[3]) ?? 0), "is_sticker": .bool(a[4] == "1")]) } : []
            return .object(["rowid": .number(Double(row[0]) ?? 0), "guid": .string(row[1]), "chat_guid": .string(row[2]),
                "sender": .string(row[3]), "text": .string(String(text.prefix(64000))), "is_from_me": .bool(row[5] == "1"),
                "is_group": .bool(participants.count != 1 || row[2].contains(";+;")), "participants": .array(participants.map(BBCJSONValue.string)),
                "created_at": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 978307200 + (Double(row[6]) ?? 0) / 1_000_000_000))),
                "service": .string(row[7]), "reply_to_guid": root.map(BBCJSONValue.string) ?? .null,
                "thread_root_guid": threadRoot.map(BBCJSONValue.string) ?? .null, "attachments": .array(attachments),
                "links": .array(RichLinks.decode(Data(hex: row[13]), text: text, attachmentGUIDs: attachmentRows.filter { $0[5].lowercased().hasSuffix(".pluginpayloadattachment") }.map { $0[0] })),
                "is_audio_message": .bool(row[14] == "1"),
                "item_type": Int(row[15]).map { BBCJSONValue.number(Double($0)) } ?? .null,
                "reaction_emoji": row[12].isEmpty ? .null : .string(row[12]),
                "is_reaction": .bool((2000..<4000).contains(reaction)), "reaction_type": .number(Double(reaction)),
                "is_reaction_add": .bool((2000..<3000).contains(reaction)),
                "reacted_to_native_guid": row[10].isEmpty ? .null : .string(row[10]), "reacted_to_guid": normalizedGUID(row[10]).map(BBCJSONValue.string) ?? .null])
        }
        return .object(["messages": .array(messages), "next_rowid": .number(values.last.flatMap { Double($0[0]) } ?? after)])
    }
    func messageStatus(_ p: [String: BBCJSONValue]) throws -> BBCJSONValue {
        guard let chat = p["chat_guid"]?.string, let guid = p["message_guid"]?.string else { throw ActionFailure.invalid }
        try verify(chat: chat, message: guid)
        let r = try rows("SELECT is_sent,is_delivered,is_read,COALESCE(error,0) FROM message WHERE guid=?1 LIMIT 2", [guid])
        guard r.count == 1 else { throw ActionFailure.unavailable }
        return .object(["guid": .string(guid), "chat_guid": .string(chat), "sent": .bool(r[0][0] == "1"), "delivered": .bool(r[0][1] == "1"), "read": .bool(r[0][2] == "1"), "error": .number(Double(r[0][3]) ?? 0), "confirmation": .string("local-database")])
    }
    func normalizedGUID(_ raw: String) -> String? {
        var reference = raw
        if reference.hasPrefix("p:") {
            let parts = reference.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, Int(parts[0].dropFirst(2)).map({ $0 >= 0 }) == true else { return nil }
            reference = String(parts[1])
        }
        if reference.hasPrefix("bp:") { reference = String(reference.dropFirst(3)) }
        return UUID(uuidString: reference)?.uuidString
    }
}
private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }; var data = Data(); var index = hex.startIndex
        while index < hex.endIndex { let next = hex.index(index, offsetBy: 2); guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }; data.append(byte); index = next }
        self = data
    }
}
