import Foundation
import SQLite3

enum ActionFailure: Error { case invalid, unavailable, busy, uncertain }

struct AudioAttachment {
    let filename: String
    let mimeType: String
    let uti: String
    let declaredBytes: Int64
}

struct VisualAttachment: Sendable {
    enum Kind: Sendable, Equatable { case image, video }
    let filename: String
    let declaredBytes: Int64
    let kind: Kind
    var maximumBytes: Int { kind == .image ? LocalVisualMedia.maximumImageBytes : LocalVisualMedia.maximumVideoBytes }
}

/// Read-only, parameterized access. Never indexes or writes Apple's database.
final class MessagesDatabase {
    private var db: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil; throw ActionFailure.unavailable
        }
        sqlite3_busy_timeout(db, 1000)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String, _ bindings: [String]) throws -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ActionFailure.unavailable }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bindings.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw ActionFailure.unavailable }
        }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, result.count < 1000 else { throw ActionFailure.unavailable }
            result.append((0..<sqlite3_column_count(stmt)).map { sqlite3_column_text(stmt, $0).map { String(cString: $0) } ?? "" })
        }
    }
    func verify(chat: String, message: String) throws {
        guard UUID(uuidString: message) != nil,
              chat.hasPrefix("any;-;") || chat.hasPrefix("iMessage;-;") else { throw ActionFailure.invalid }
        let rows = try rows("""
            SELECT m.service, c.chat_identifier,
              (SELECT count(*) FROM chat_handle_join h WHERE h.chat_id=c.ROWID)
            FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
            JOIN chat c ON c.ROWID=j.chat_id WHERE m.guid=?1 AND c.guid=?2 LIMIT 2
            """, [message, chat])
        guard rows.count == 1, rows[0][0] == "iMessage", rows[0][2] == "1",
              chat == "any;-;" + rows[0][1] || chat == "iMessage;-;" + rows[0][1] else { throw ActionFailure.invalid }
    }
    func maximumRowID() throws -> Int64 {
        guard let v = try rows("SELECT COALESCE(MAX(ROWID),0) FROM message", []).first?.first, let id = Int64(v) else { throw ActionFailure.unavailable }
        return id
    }
    func threadRoot(chat: String, message: String) throws -> String {
        try verify(chat: chat, message: message)
        let raw = try rows("SELECT m.thread_originator_guid FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE c.guid=?1 AND m.guid=?2 LIMIT 2", [chat,message]).first?.first ?? ""
        let value = raw.isEmpty ? message : raw
        guard let guid = normalizedGUID(value) else { throw ActionFailure.invalid }
        return guid
    }
    func confirmedReply(chat: String, root: String, text: String, after: Int64) throws -> String? {
        let values = try rows("""
            SELECT m.guid,m.thread_originator_guid FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id
            WHERE c.guid=?1 AND m.ROWID>CAST(?2 AS INTEGER) AND m.is_from_me=1 AND m.service='iMessage'
            AND m.text=?3 AND m.is_sent=1 AND COALESCE(m.error,0)=0 LIMIT 1000
            """,[chat,String(after),text]).filter { normalizedGUID($0[1]) == root }
        guard values.count <= 1 else { throw ActionFailure.uncertain }
        return values.first?.first
    }
    func reaction(chat: String, message: String) throws -> Int? {
        try reactionValue(chat: chat, message: message).flatMap { NativeRequest.reactions.firstIndex(of: $0) }
    }
    func optionalMessageColumn(_ name: String, fallback: String = "''") throws -> String {
        try rows("PRAGMA table_info(message)", []).contains { $0[1] == name } ? "COALESCE(m.\(name),\(fallback))" : fallback
    }
    func reactionValue(chat: String, message: String) throws -> String? {
        let emoji = try optionalMessageColumn("associated_message_emoji")
        let values = try rows("""
            SELECT m.associated_message_type, \(emoji) FROM message m
            JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id
            WHERE c.guid=?1 AND m.is_from_me=1 AND m.service='iMessage'
              AND m.associated_message_guid IN (?2, ?3)
              AND (m.associated_message_type BETWEEN 2000 AND 2007 OR m.associated_message_type BETWEEN 3000 AND 3007)
            ORDER BY m.ROWID DESC LIMIT 1
            """, [chat, message, "p:0/" + message])
        guard let row = values.first, let type = Int(row[0]) else { return nil }
        if (2000...2005).contains(type) { return NativeRequest.reactions[type - 2000] }
        return type == 2006 && EmojiTapback.valid(row[1]) ? row[1] : nil
    }
    func audioAttachment(chat: String, message: String, attachment: String) throws -> AudioAttachment {
        try verify(chat: chat, message: message)
        guard !attachment.isEmpty, attachment.utf8.count <= 256, !attachment.utf8.contains(0) else { throw ActionFailure.invalid }
        let values = try rows("""
            SELECT a.filename, a.mime_type, a.uti, a.total_bytes
            FROM attachment a JOIN message_attachment_join ma ON ma.attachment_id=a.ROWID
            JOIN message m ON m.ROWID=ma.message_id
            JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
            WHERE a.guid=?1 AND m.guid=?2 AND c.guid=?3
              AND m.is_from_me=0 AND m.item_type=0 LIMIT 2
            """, [attachment, message, chat])
        guard values.count == 1, let row = values.first, !row[0].isEmpty,
              let size = Int64(row[3]), size >= 0, size <= AttachmentFile.maximumBytes,
              row[1].hasPrefix("audio/") || ["com.apple.coreaudio-format", "public.mp3", "public.mpeg-4-audio", "com.microsoft.waveform-audio", "public.aiff-audio"].contains(row[2]) else { throw ActionFailure.invalid }
        return .init(filename: row[0], mimeType: row[1], uti: row[2], declaredBytes: size)
    }
    func visualAttachment(chat: String, message: String, attachment: String) throws -> VisualAttachment {
        try verify(chat: chat, message: message)
        guard !attachment.isEmpty, attachment.utf8.count <= 256, !attachment.utf8.contains(0) else { throw ActionFailure.invalid }
        let values = try rows("""
            SELECT a.filename, a.mime_type, a.uti, a.total_bytes
            FROM attachment a JOIN message_attachment_join ma ON ma.attachment_id=a.ROWID
            JOIN message m ON m.ROWID=ma.message_id
            JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
            WHERE a.guid=?1 AND m.guid=?2 AND c.guid=?3
              AND m.is_from_me=0 AND m.item_type=0 LIMIT 2
            """, [attachment, message, chat])
        guard values.count == 1, let row = values.first, !row[0].isEmpty,
              let size = Int64(row[3]), size >= 0 else { throw ActionFailure.invalid }
        let imageTypes = ["public.image", "public.jpeg", "public.png", "public.heic", "public.heif", "com.compuserve.gif", "public.tiff", "org.webmproject.webp"]
        let videoTypes = ["public.movie", "public.mpeg-4", "com.apple.quicktime-movie"]
        let kind: VisualAttachment.Kind
        if row[1].hasPrefix("image/") || imageTypes.contains(row[2]) { kind = .image }
        else if row[1].hasPrefix("video/") || videoTypes.contains(row[2]) { kind = .video }
        else { throw ActionFailure.invalid }
        let result = VisualAttachment(filename: row[0], declaredBytes: size, kind: kind)
        guard size <= result.maximumBytes else { throw ActionFailure.invalid }
        return result
    }
    func unread(chat: String) throws -> [String] {
        // Apple/Beeper exclude conversation actions (e.g. background changes)
        // from message unread state. Such rows can permanently retain is_read=0.
        // Keep every actual incoming item, even when it has no plain text.
        try rows("""
            SELECT m.guid FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
            JOIN chat c ON c.ROWID=j.chat_id
            WHERE c.guid=?1 AND m.is_from_me=0 AND m.is_read=0 AND m.item_type=0 ORDER BY m.ROWID
            """, [chat]).map { $0[0] }
    }
    /// Bounded identity/type metadata for this authorized chat, never message text.
    func unreadOutsideScope(chat: String, consumed: Set<String>) throws -> [[String: String]] {
        let columns = try rows("PRAGMA table_info(message)", []).map { $0[1] }
        let system = columns.contains("is_system_message") ? "COALESCE(m.is_system_message,0)" : "0"
        let extra = ["item_type", "group_action_type", "is_empty", "is_service_message", "is_sent", "is_finished", "error", "date", "date_read", "date_retracted"].filter(columns.contains)
        var keys = ["guid", "service", "associated_type", "system"] + extra
        var fields = ["m.guid", "m.service", "COALESCE(m.associated_message_type,0)", system] + extra.map { "m." + $0 }
        for column in ["text", "attributedBody"] where columns.contains(column) {
            keys.append(column + "_length"); fields.append("COALESCE(length(m." + column + "),0)")
        }
        return try rows("""
            SELECT \(fields.joined(separator: ","))
            FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
            JOIN chat c ON c.ROWID=j.chat_id
            WHERE c.guid=?1 AND m.is_from_me=0 AND m.is_read=0 AND m.item_type=0 ORDER BY m.ROWID
            """, [chat]).filter { !consumed.contains($0[0]) }.prefix(10).map {
                Dictionary(uniqueKeysWithValues: zip(keys, $0))
            }
    }
}

struct NativeRequest: Decodable {
    let method: String
    let params: Parameters?
    var trace_id: String?
    struct Parameters: Decodable {
        let chat_guid: String
        let message_guid: String?
        let reaction: String?
        let remove: Bool?
        let read_guids: [String]?
        let attachment_guid: String?
        let text: String?
        let typing_id: String?
        let deadline: Double?
        let url: String?
    }
    static let reactions = ["love", "like", "dislike", "laugh", "emphasis", "question"]
    static let beeperReactions = ["heart", "like", "dislike", "laugh", "emphasize", "question"]
    func validated() throws -> Parameters {
        guard let params, ["tapback", "read", "read.status", "media.transcribe", "media.visual", "reply", "link", "typing.start"].contains(method), params.chat_guid.utf8.count <= 512,
              let guid = params.message_guid, UUID(uuidString: guid) != nil else { throw ActionFailure.invalid }
        if method == "tapback" { guard Self.reactions.contains(params.reaction ?? "") || EmojiTapback.valid(params.reaction ?? "") else { throw ActionFailure.invalid } }
        if ["media.transcribe", "media.visual"].contains(method) {
            guard let attachment = params.attachment_guid, !attachment.isEmpty, attachment.utf8.count <= 256,
                  !attachment.utf8.contains(0) else { throw ActionFailure.invalid }
        }
        if method == "link" { guard let url = params.url, RichLinks.validURL(url) != nil else { throw ActionFailure.invalid } }
        if method == "reply" { guard let text = params.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 64000 else { throw ActionFailure.invalid } }
        if method == "typing.start" { guard params.typing_id.flatMap(UUID.init(uuidString:)) != nil, let deadline = params.deadline, deadline.isFinite, deadline > Date().timeIntervalSince1970 * 1000, deadline <= (Date().timeIntervalSince1970 + 31) * 1000 else { throw ActionFailure.invalid } }
        if ["read", "read.status", "reply", "link", "typing.start"].contains(method) {
            guard let ids = params.read_guids, !ids.isEmpty, ids.count <= 200,
                  Set(ids).count == ids.count, (["reply", "link"].contains(method) || ids.contains(guid)), ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw ActionFailure.invalid }
        }
        return params
    }
    static func isDesired(current: Int?, reaction: Int, remove: Bool) -> Bool {
        remove ? current != reaction : current == reaction
    }
}
