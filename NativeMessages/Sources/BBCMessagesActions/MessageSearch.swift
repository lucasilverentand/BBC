import Foundation
import IMDatabase
import BBCClient

extension MessagesDatabase {
    /// Descending native row cursor. A bounded scan also searches attributed-only
    /// bodies without relying on SQLite's ASCII-only LIKE case folding.
    func search(_ parameters: [String: BBCJSONValue]) throws -> BBCJSONValue {
        let text = try SearchFilter.optionalText(parameters["text"], maximum: 512)
        let chat = try SearchFilter.optionalText(parameters["chat_guid"], maximum: 512)
        let from = try SearchFilter.date(parameters["from"])
        let to = try SearchFilter.date(parameters["to"])
        guard text != nil || chat != nil || from != nil || to != nil,
              from == nil || to == nil || from! < to! else { throw ActionFailure.invalid }
        let before = parameters["before_rowid"]?.numberValue ?? 9_007_199_254_740_991
        let beforeChat = try SearchFilter.optionalText(parameters["before_chat_guid"],maximum:512)
        let limit = parameters["limit"]?.numberValue ?? 50
        guard parameters["before_rowid"] == nil || parameters["before_rowid"]?.numberValue != nil,
              parameters["limit"] == nil || parameters["limit"]?.numberValue != nil,
              before.isFinite, before > 0, before <= 9_007_199_254_740_991, before.rounded() == before,
              limit.isFinite, limit >= 1, limit <= 200, limit.rounded() == limit else { throw ActionFailure.invalid }
        var result: [BBCJSONValue] = [], last = before, lastChat = beforeChat ?? "", scanned = 0, more = false
        while scanned < 400, result.count < Int(limit) {
        let batch = min(25,400-scanned)
        let rows = try rows("""
            SELECT m.ROWID,m.guid,c.guid,COALESCE(substr(m.text,1,64000),''),CASE WHEN length(m.attributedBody)<=256000 THEN hex(m.attributedBody) ELSE '' END,m.date,
                COALESCE(m.is_from_me,0),COALESCE(m.service,'')
            FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID
            JOIN chat c ON c.ROWID=j.chat_id
            WHERE (m.ROWID<CAST(?1 AS INTEGER) OR (?5!='' AND m.ROWID=CAST(?1 AS INTEGER) AND c.guid>?5)) AND (?2='' OR c.guid=?2)
              AND (?3='' OR m.date>=CAST(?3 AS INTEGER)) AND (?4='' OR m.date<CAST(?4 AS INTEGER))
            ORDER BY m.ROWID DESC,c.guid LIMIT ?6
            """, [String(Int64(last)),chat ?? "",from.map(String.init) ?? "",to.map(String.init) ?? "",lastChat,String(batch+1)])
        var visited = 0
        for row in rows.prefix(batch) {
            visited += 1
            scanned += 1; last = Double(row[0]) ?? before; lastChat = row[2]
            var body = row[3]
            if body.isEmpty, let data = SearchFilter.data(hex: row[4], maximum: 256_000) {
                body = Self.decodedMessageBody(data)
            }
            if let text, body.range(of:text,options:[.caseInsensitive,.diacriticInsensitive]) == nil { continue }
            result.append(.object([
                "rowid":.number(last),"guid":.string(row[1]),"chat_guid":.string(row[2]),
                "text":.string(String(body.prefix(1000))),"text_truncated":.bool(body.count > 1000),"is_from_me":.bool(row[6] == "1"),
                "service":.string(row[7]),"created_at":.string(SearchFilter.isoDate(Double(row[5]) ?? 0))
            ]))
            if result.count == Int(limit) { break }
        }
        more = visited < rows.count
        if !more { break }
        }
        return .object(["messages":.array(result),"next_before_rowid":.number(last),"next_before_chat_guid":.string(lastChat),
                        "more":.bool(more),"scanned":.number(Double(scanned))])
    }
    static func decodedMessageBody(_ data: Data) -> String { (try? AttributedBodyDecoder.plainText(from:data)) ?? "" }
}

enum SearchFilter {
    static func optionalText(_ value: BBCJSONValue?, maximum: Int) throws -> String? {
        guard let value else { return nil }
        guard let text = value.string, !text.isEmpty, text.utf8.count <= maximum,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { throw ActionFailure.invalid }
        return text
    }
    static func date(_ value: BBCJSONValue?) throws -> Int64? {
        guard let value else { return nil }
        guard let text = value.string, text.utf8.count <= 64 else { throw ActionFailure.invalid }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        guard let date = fractional.date(from:text) ?? ISO8601DateFormatter().date(from:text) else { throw ActionFailure.invalid }
        let native = (date.timeIntervalSince1970 - 978_307_200) * 1_000_000_000
        guard native.isFinite, native >= Double(Int64.min), native < Double(Int64.max) else { throw ActionFailure.invalid }
        return Int64(native)
    }
    static func isoDate(_ native: Double) -> String {
        ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:978_307_200+native/1_000_000_000))
    }
    static func data(hex: String, maximum: Int) -> Data? {
        guard hex.count % 2 == 0, hex.utf8.count <= maximum * 2 else { return nil }
        var result = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index,offsetBy:2)
            guard let byte = UInt8(hex[index..<next],radix:16) else { return nil }
            result.append(byte); index = next
        }
        return result
    }
}
