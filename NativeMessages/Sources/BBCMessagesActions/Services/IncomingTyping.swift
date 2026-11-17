import Foundation
import BBCClient

/// Connection-local ephemeral state. No replay ID, database write or message content.
struct IncomingTypingLease {
    private struct Active { let sender: String; let expires: Double }
    private var active: Active?
    private var seenSource: String?
    mutating func update(_ snapshot: BBCJSONValue?, chat: String, now: Double) -> Data {
        var events: [BBCJSONValue] = []
        func packet(_ state: String, sender: String, expires: Double) -> BBCJSONValue {
            .object(["type":.string("typing."+state),"chat_guid":.string(chat),"sender_handle":.string(sender),
                     "observed_at":.number(now),"expires_at":.number(expires),"ttl_ms":.number(max(0,expires-now))])
        }
        if let current = active, current.expires <= now {
            events.append(packet("expired",sender:current.sender,expires:current.expires)); active = nil
        }
        let fields = snapshot?.object
        if fields?["ok"]?.bool == true, fields?["chat_guid"]?.string == chat {
            if fields?["active"]?.bool == false {
                if let current = active { events.append(packet("stopped",sender:current.sender,expires:now)) }
                active = nil; seenSource = nil
            } else if fields?["active"]?.bool == true,
                      let sender = fields?["sender_handle"]?.string, !sender.isEmpty, sender.utf8.count <= 254, !sender.utf8.contains(0),
                      let source = fields?["source_guid"]?.string, !source.isEmpty, source.utf8.count <= 256,
                      let expires = fields?["expires_at"]?.numberValue, expires.isFinite, expires > now, expires <= now+8000,
                      source != seenSource {
                if let current = active { events.append(packet("stopped",sender:current.sender,expires:now)) }
                active = Active(sender:sender,expires:expires); seenSource = source
                events.append(packet("started",sender:sender,expires:expires))
            }
        }
        return events.reduce(into:Data()) { data,event in
            if let body = try? JSONEncoder().encode(event) { data += Data("event: bbc.typing\ndata: ".utf8)+body+Data("\n\n".utf8) }
        }
    }
}

/// Fixed diagnostic fields only. Never forward raw native packets or source identities.
enum IncomingTypingDiagnostic {
    static func packet(_ snapshot: BBCJSONValue?, now: Double) -> BBCJSONValue {
        let fields = snapshot?.object
        var result: [String:BBCJSONValue] = ["available":.bool(fields?["ok"]?.bool == true)]
        if fields?["ok"]?.bool == true {
            let active = fields?["active"]?.bool == true
            result["state"] = .string(active ? ((fields?["expires_at"]?.numberValue ?? 0) > now ? "typing" : "expired") : "idle")
            for key in ["has_incoming","current_indicator","typing_message","cancelled","from_me"] {
                if let flag = fields?["observation"]?.object?[key]?.bool { result[key] = .bool(flag) }
            }
        } else {
            let code = fields?["failure_code"]?.string ?? "native_sample_unavailable"
            let allowed = ["incoming_typing_unsupported","native_chat_missing","incoming_typing_direct_chat_required","incoming_typing_identity_unavailable","incoming_typing_unavailable"]
            result["reason"] = .string(allowed.contains(code) ? code : "native_sample_unavailable")
        }
        return .object(result)
    }
}
