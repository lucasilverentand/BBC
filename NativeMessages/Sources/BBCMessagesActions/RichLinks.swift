import Foundation
import BBCClient

/// Parse bounded property lists without instantiating archived Objective-C classes.
/// Apple's URL balloons store richLinkMetadata in payload_data.
enum RichLinks {
    static func validURL(_ value: String) -> String? {
        guard value.utf8.count <= 8192, !value.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 32 }),
              let url = URLComponents(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return value
    }

    static func decode(_ data: Data?, text: String, attachmentGUIDs: [String]) -> [BBCJSONValue] {
        var links: [BBCJSONValue] = []
        if let data, data.count <= 256_000,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            var budget = 2048
            let archive = plist as? [String: Any]
            let objects = archive?["$objects"] as? [Any] ?? []
            let root = (archive?["$top"] as? [String: Any])?["root"] ?? plist
            func resolve(_ value: Any, depth: Int = 0) -> Any? {
                budget -= 1
                guard budget >= 0, depth < 24 else { return nil }
                var uid = (value as? [String: Any])?["CF$UID"] as? Int
                if uid == nil, !(value is [String: Any]), !(value is [Any]) {
                    let description = String(describing: value)
                    if description.contains("CFKeyedArchiverUID"), let start = description.range(of: "value = "),
                       let end = description[start.upperBound...].firstIndex(of: "}") {
                        uid = Int(description[start.upperBound..<end].trimmingCharacters(in: .whitespaces))
                    }
                }
                if let uid { return objects.indices.contains(uid) ? resolve(objects[uid], depth: depth + 1) : nil }
                if let dictionary = value as? [String: Any] {
                    var result: [String: Any] = [:]
                    for (key, child) in dictionary where key != "$class" && key != "$classes" {
                        result[key] = resolve(child, depth: depth + 1)
                    }
                    if let keys = result["NS.keys"] as? [String], let values = result["NS.objects"] as? [Any], keys.count == values.count {
                        return Dictionary(zip(keys, values), uniquingKeysWith: { first, _ in first })
                    }
                    return result
                }
                if let array = value as? [Any] { return array.compactMap { resolve($0, depth: depth + 1) } }
                return value
            }
            if let payload = resolve(root) as? [String: Any], let metadata = payload["richLinkMetadata"] as? [String: Any] {
                func url(_ value: Any?) -> String? {
                    (value as? String ?? (value as? [String: Any])?["NS.relative"] as? String).flatMap(validURL)
                }
                if let address = url(metadata["originalURL"]) ?? url(metadata["URL"]) {
                    var link: [String: BBCJSONValue] = ["url": .string(address), "preview": .bool(true)]
                    for field in ["title", "summary", "siteName"] {
                        if let value = metadata[field] as? String { link[field] = .string(String(value.prefix(2048))) }
                    }
                    for field in ["image", "icon"] {
                        if let index = (metadata[field] as? [String: Any])?["richLinkImageAttachmentSubstituteIndex"] as? Int,
                           attachmentGUIDs.indices.contains(index) { link[field + "_attachment_guid"] = .string(attachmentGUIDs[index]) }
                    }
                    links.append(.object(link))
                }
            }
        }
        if links.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            links = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(20).compactMap {
                guard let value = $0.url?.absoluteString, let address = validURL(value) else { return nil }
                return .object(["url": .string(address), "preview": .bool(false)])
            }
        }
        return links
    }
}

extension MessagesDatabase {
    func confirmedLink(chat: String, text: String, after: Int64) throws -> String? {
        let values = try rows("""
            SELECT m.guid FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id
            WHERE c.guid=?1 AND m.ROWID>CAST(?2 AS INTEGER) AND m.is_from_me=1 AND m.service='iMessage'
            AND m.text=?3 AND m.is_sent=1 AND COALESCE(m.error,0)=0 AND COALESCE(m.thread_originator_guid,'')='' LIMIT 2
            """, [chat, String(after), text])
        guard values.count <= 1 else { throw ActionFailure.uncertain }
        return values.first?.first
    }
}
