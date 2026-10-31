import Foundation
import BBCClient
import IMDatabase

/// Parameters exposed by BBC; filesystem paths and private selectors never
/// cross the public API. The worker adds validated native handoffs afterwards.
struct AdvancedRequest {
    static let methods = Set(["groups.create","groups.add","groups.remove","groups.name","groups.photo","groups.leave","messages.edit","messages.unsend","messages.multipart","availability"])
    let method: String
    let params: [String: BBCJSONValue]
    static func address(_ value: String) -> Bool {
        value.utf8.count <= 254 && !value.utf8.contains(0) && value.range(of:#"^(\+[1-9][0-9]{6,14}|[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)$"#,options:.regularExpression) != nil
    }
    static func chat(_ value: String) -> Bool {
        !value.utf8.contains(0) && value.utf8.count <= 512 && ["any;-;","iMessage;-;","any;+;","iMessage;+;"].contains(where:value.hasPrefix)
    }
    static func effect(_ value: String) -> Bool {
        value.utf8.count <= 160 && !value.utf8.contains(0) && ["com.apple.messages.effect.","com.apple.MobileSMS.expressivesend."].contains(where:value.hasPrefix)
    }
    init(_ payload: BBCJSONValue) throws {
        guard let method = payload.object?["method"]?.string, Self.methods.contains(method), let params = payload.object?["params"]?.object else { throw ActionFailure.invalid }
        self.method = method; self.params = params
        let fields: [String:Set<String>] = [
            "groups.create":["participants","name"], "groups.add":["chat_guid","participants"], "groups.remove":["chat_guid","participants"],
            "groups.name":["chat_guid","name"], "groups.photo":["chat_guid","media_id"], "groups.leave":["chat_guid"],
            "messages.edit":["chat_guid","message_guid","text","part_index"], "messages.unsend":["chat_guid","message_guid","part_index"],
            "messages.multipart":["chat_guid","text","media_ids","effect"], "availability":["address"]]
        guard Set(params.keys).isSubset(of:fields[method]!) else { throw ActionFailure.invalid }
        if method == "availability" {
            guard let value = params["address"]?.string, Self.address(value) else { throw ActionFailure.invalid }; return
        }
        if method != "groups.create" {
            guard let chat = params["chat_guid"]?.string, Self.chat(chat), !method.hasPrefix("groups.") || chat.contains(";+;") else { throw ActionFailure.invalid }
        }
        if ["groups.create","groups.add","groups.remove"].contains(method) {
            guard case .array(let raw) = params["participants"], raw.count >= (method == "groups.create" ? 2 : 1), raw.count <= 32 else { throw ActionFailure.invalid }
            let values = raw.compactMap(\.string)
            guard values.count == raw.count, Set(values.map { $0.lowercased() }).count == values.count, values.allSatisfy(Self.address) else { throw ActionFailure.invalid }
        }
        if method == "groups.name" || params["name"] != nil {
            guard let name = params["name"]?.string, !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.utf8.count <= 256, !name.utf8.contains(0) else { throw ActionFailure.invalid }
        }
        if method == "groups.photo" { guard params["media_id"]?.string.flatMap(UUID.init(uuidString:)) != nil else { throw ActionFailure.invalid } }
        if ["messages.edit","messages.unsend"].contains(method) {
            guard params["message_guid"]?.string.flatMap(UUID.init(uuidString:)) != nil else { throw ActionFailure.invalid }
            if let value = params["part_index"] {
                guard let number = value.numberValue, number.isFinite, number.rounded() == number, (0...63).contains(number) else { throw ActionFailure.invalid }
            }
        }
        if method == "messages.edit" || params["text"] != nil {
            guard let text = params["text"]?.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count <= 64000, !text.utf8.contains(0) else { throw ActionFailure.invalid }
        }
        if method == "messages.multipart" {
            let raw: [BBCJSONValue]
            if let value = params["media_ids"] { guard case .array(let values) = value else { throw ActionFailure.invalid }; raw = values }
            else { raw = [] }
            let ids = raw.compactMap { $0.string.flatMap(UUID.init(uuidString:)) }
            guard raw.count <= 8, ids.count == raw.count, Set(ids).count == ids.count, !raw.isEmpty || params["text"]?.string != nil else { throw ActionFailure.invalid }
            if let value = params["effect"] { guard let effect = value.string, Self.effect(effect) else { throw ActionFailure.invalid } }
        }
    }
}

@MainActor enum AdvancedActions {
    static func perform(_ payload: BBCJSONValue) async -> BBCJSONValue {
        var dispatched = false
        do {
            let request = try AdvancedRequest(payload)
            let lock = try NativeOperationLock(name:"automation.lock"); defer { lock.release() }
            var fields = request.params; fields["method"] = .string(request.method)
            let db: MessagesDatabase?
            if ["availability","groups.create"].contains(request.method) { db = nil }
            else {
                db = try MessagesDatabase(url:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"))
                try db!.verifyAdvancedChat(request.params["chat_guid"]!.string!, group:request.method.hasPrefix("groups."))
            }
            if ["messages.edit","messages.unsend"].contains(request.method) {
                try db!.verifyOwnChange(chat:request.params["chat_guid"]!.string!,message:request.params["message_guid"]!.string!,edit:request.method == "messages.edit")
            }
            var uploads: [MediaStore.Upload] = []
            if request.method == "groups.photo" {
                let (upload,source) = try MediaStore().resolve(request.params["media_id"]!.string!)
                guard upload.mimeType.hasPrefix("image/") else { throw ActionFailure.invalid }
                fields["file_path"] = .string(try MediaStore.stageHandoff(upload:upload,source:source,directory:MediaStore.nativeHandoffDirectory).path)
                fields.removeValue(forKey:"media_id"); uploads.append(upload)
            }
            if request.method == "messages.multipart" {
                let raw: [BBCJSONValue]
                if case .array(let values) = fields.removeValue(forKey:"media_ids") { raw = values } else { raw = [] }
                var files: [BBCJSONValue] = [], total = 0
                let store = try MediaStore()
                // Resolve every upload before creating any handoff or native call.
                let resolved = try raw.map { try store.resolve($0.string!) }
                for (upload,_) in resolved { total += upload.bytes }
                guard total <= MediaStore.maximumBytes else { throw ActionFailure.invalid }
                for (upload,source) in resolved {
                    let file = try MediaStore.stageHandoff(upload:upload,source:source,directory:MediaStore.nativeHandoffDirectory)
                    files.append(.object(["file_path":.string(file.path)])); uploads.append(upload)
                }
                fields["files"] = .array(files)
            }
            let before = try db?.maximumRowID() ?? 0
            let packet = BBCJSONValue.object(fields)
            let native = try await Task.detached { try NativeBridgeClient.request(packet) }.value
            guard native.object?["ok"]?.bool == true else { return native }
            if request.method != "messages.multipart" { return native }
            dispatched = true
            guard let guid = native.object?["guid"]?.string, UUID(uuidString:guid) != nil else { throw ActionFailure.uncertain }
            let chat = request.params["chat_guid"]!.string!
            try await BBCMessagesActions.confirm {
                try db!.confirmedMultipart(chat:chat,guid:guid,text:request.params["text"]?.string,uploads:uploads,effect:request.params["effect"]?.string,after:before)
            }
            // Remove only files whose exact message completed a copy into native
            // attachment storage. Uncertain transfers remain quota bounded.
            for upload in uploads where (try? db!.handoffCopied(message:guid,upload:upload)) == true {
                try? MediaStore.removeHandoff(upload:upload,directory:MediaStore.nativeHandoffDirectory)
            }
            return .object(["ok":.bool(true),"guid":.string(guid),"chat_guid":.string(chat),"confirmation":.string("local-database")])
        } catch {
            let uncertain = dispatched || (error as? ActionFailure) == .uncertain
            return .object(["ok":.bool(false),"uncertain":.bool(uncertain),"failure_code":.string(uncertain ? "native_effect_unconfirmed" : "native_request_unavailable")])
        }
    }
}

extension MessagesDatabase {
    func verifyAdvancedChat(_ chat: String, group: Bool) throws {
        guard AdvancedRequest.chat(chat), !group || chat.contains(";+;") else { throw ActionFailure.invalid }
        let columns = try rows("PRAGMA table_info(chat)",[]).map { $0[1] }
        let service = columns.contains("service_name") ? "COALESCE(c.service_name,'')" : "(SELECT m.service FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID WHERE j.chat_id=c.ROWID ORDER BY m.ROWID DESC LIMIT 1)"
        let matches = try rows("SELECT \(service),(SELECT COUNT(*) FROM chat_handle_join h WHERE h.chat_id=c.ROWID) FROM chat c WHERE c.guid=?1 LIMIT 2",[chat])
        guard matches.count == 1, matches[0][0] == "iMessage", let participants = Int(matches[0][1]), participants >= (chat.contains(";+;") ? 2 : 1), chat.contains(";+;") || participants == 1 else { throw ActionFailure.invalid }
    }
    func verifyOwnChange(chat: String, message: String, edit: Bool, now: Date = Date()) throws {
        guard UUID(uuidString:message) != nil else { throw ActionFailure.invalid }
        let matches = try rows("SELECT m.is_from_me,m.is_sent,m.date,COALESCE(m.error,0) FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id WHERE m.guid=?1 AND c.guid=?2 AND m.service='iMessage' LIMIT 2",[message,chat])
        guard matches.count == 1, matches[0][0] == "1", matches[0][1] == "1", matches[0][3] == "0", let timestamp = Double(matches[0][2]), timestamp.isFinite else { throw ActionFailure.invalid }
        let age = now.timeIntervalSince1970 - (978307200 + timestamp/1_000_000_000)
        guard age >= 0, age <= (edit ? 900 : 120) else { throw ActionFailure.invalid }
    }
    func confirmedMultipart(chat: String, guid: String, text: String?, uploads: [MediaStore.Upload], effect: String?, after: Int64) throws -> Bool {
        let effectColumn = try optionalMessageColumn("expressive_send_style_id")
        let match = try rows("""
            SELECT COALESCE(m.text,''),CASE WHEN length(m.attributedBody)<=2000000 THEN hex(m.attributedBody) ELSE '' END,\(effectColumn)
            FROM message m JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id
            WHERE m.guid=?1 AND c.guid=?2 AND m.ROWID>CAST(?3 AS INTEGER) AND m.is_from_me=1 AND m.service='iMessage'
            AND m.is_sent=1 AND COALESCE(m.error,0)=0 LIMIT 2
            """,[guid,chat,String(after)])
        guard match.count == 1 else { return false }
        var body = match[0][0]
        if body.isEmpty, let bytes = Self.advancedHex(match[0][1]) { body = (try? AttributedBodyDecoder.plainText(from:bytes)) ?? "" }
        let expectedBody = (text ?? "") + String(repeating:"\u{fffc}",count:uploads.count)
        guard body == expectedBody, effect == nil || match[0][2] == effect else { return false }
        let files = try rows("SELECT a.transfer_name FROM attachment a JOIN message_attachment_join j ON j.attachment_id=a.ROWID JOIN message m ON m.ROWID=j.message_id WHERE m.guid=?1 ORDER BY a.ROWID LIMIT 9",[guid]).compactMap(\.first)
        return files.count == uploads.count && Set(files) == Set(uploads.map(\.filename))
    }
    private static func advancedHex(_ value: String) -> Data? {
        let characters = Array(value.utf8)
        guard characters.count <= 4_000_000, characters.count.isMultiple(of:2) else { return nil }
        var result = Data(capacity:characters.count/2)
        for index in stride(from:0,to:characters.count,by:2) {
            guard let byte = UInt8(String(decoding:characters[index...index+1],as:UTF8.self),radix:16) else { return nil }
            result.append(byte)
        }
        return result
    }
}
