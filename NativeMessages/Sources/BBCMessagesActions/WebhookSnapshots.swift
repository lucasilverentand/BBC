import Foundation
import BBCClient

extension MessagesDatabase {
    func webhookSnapshots(after: Int64, afterChat: String = "", through: Int64? = nil, throughChat: String = "", limit: Int, descending: Bool = false) throws -> [WebhookSnapshot] {
        guard after >= 0, (1...200).contains(limit) else { throw ActionFailure.invalid }
        let columns = try rows("PRAGMA table_info(message)",[]).map { $0[1] }
        let names = ["is_sent","is_delivered","is_read","error","date_read","date_delivered","date_edited","date_retracted","associated_message_type","associated_message_guid","associated_message_emoji"]
        let fields = names.map { columns.contains($0) ? "COALESCE(m.\($0),'')" : "''" }
        let values = try rows("""
            SELECT m.ROWID,m.guid,c.guid,COALESCE(substr(m.text,1,64000),''),COALESCE(m.is_from_me,0),COALESCE(m.service,''),m.date,\(fields.joined(separator:",")),
                CASE WHEN length(m.attributedBody)<=64000 THEN hex(m.attributedBody) ELSE '' END
            FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id
            WHERE (m.ROWID>CAST(?1 AS INTEGER) OR (m.ROWID=CAST(?1 AS INTEGER) AND c.guid>?4))
              AND (m.ROWID<CAST(?2 AS INTEGER) OR (m.ROWID=CAST(?2 AS INTEGER) AND (?5='' OR c.guid<=?5)))
            ORDER BY m.ROWID \(descending ? "DESC" : "ASC"),c.guid LIMIT ?3
            """, [String(after),String(through ?? Int64.max),String(limit),afterChat,throughChat])
        return values.map { row in
            var body = row[3]
            if body.isEmpty, let data = SearchFilter.data(hex:row[7+names.count],maximum:64000) { body = Self.decodedMessageBody(data) }
            var packet: [String:BBCJSONValue] = ["rowid":.number(Double(row[0]) ?? 0),"guid":.string(row[1]),"chat_guid":.string(row[2]),
                                               "text":.string(String(body.prefix(16_000))),"text_truncated":.bool(body.count > 16_000),"is_from_me":.bool(row[4] == "1"),"service":.string(row[5]),"created_at":.string(SearchFilter.isoDate(Double(row[6]) ?? 0))]
            for (index,name) in names.enumerated() {
                let value = row[index+7]
                if !columns.contains(name) { packet[name] = .null }
                else if ["is_sent","is_delivered","is_read"].contains(name) { packet[name] = .bool(value == "1") }
                else if ["error","associated_message_type"].contains(name) { packet[name] = .number(Double(value) ?? 0) }
                else if name.hasPrefix("date_") { packet[name] = (Double(value) ?? 0) > 0 ? .string(SearchFilter.isoDate(Double(value) ?? 0)) : .null }
                else { packet[name] = value.isEmpty ? .null : .string(value) }
            }
            return .init(rowID:Int64(row[0]) ?? 0,key:row[2]+"\u{1f}"+row[1],incoming:row[4] != "1",payload:.object(packet))
        }
    }
}
