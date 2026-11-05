import Foundation
import BBCClient
import Darwin

/// Explicit resources for one worker request. `production` retains every default path and timing.
struct NativeWorkerEnvironment: Sendable {
    var databaseURL: URL
    var endpoint: BridgeWire.Endpoint?
    var lockDirectory: URL?
    var bridgeTimeout = 25
    var confirmationTimeout: TimeInterval = 5
    var confirmationInterval = 100
    static var production: NativeWorkerEnvironment {
        NativeWorkerEnvironment(databaseURL:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"))
    }
}

/// Native calls only. This worker has no Accessibility or keyboard/mouse path.
enum BBCMessagesActions {
    @MainActor static func main() async {
        var attempted = false, phase = "request_input"
        var trace: NativeActionTrace?
        var receipt: [String:Any]
        do {
            guard getuid() != 0, geteuid() == getuid() else { throw ActionFailure.invalid }
            if CommandLine.arguments.contains("--typing-session") {
                phase = "operating_mode"
                guard OperatingMode.current == .full else { throw ActionFailure.invalid }
                try await NativeTypingSession.run(decoded:{ trace = NativeActionTrace($0) },progress:{ phase = $0; attempted = $1; trace?.record($0,attempted:$1) })
                return
            }
            var input = Data()
            while let data = try FileHandle.standardInput.read(upToCount:8192), !data.isEmpty {
                guard input.count + data.count <= 65536 else { throw ActionFailure.invalid }; input.append(data)
            }
            phase = "operating_mode"
            let decoded = try JSONDecoder().decode(BBCJSONValue.self,from:input)
            guard let method = decoded.object?["method"]?.string, OperatingMode.current.allows(method:method) else { throw ActionFailure.invalid }
            let envelope = try JSONDecoder().decode(BBCJSONValue.self,from:input)
            if let method = envelope.object?["method"]?.string, AdvancedRequest.methods.contains(method) {
                let result = await AdvancedActions.perform(envelope)
                FileHandle.standardOutput.write(try JSONEncoder().encode(result) + Data([10])); return
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:await perform(input:input),options:.sortedKeys) + Data([10])); return
        } catch {
            if let failure = error as? ActionFailure, failure == .uncertain { attempted = true }
            receipt = ["ok":false,"uncertain":attempted,"failure_code":phase,"error":"Native action unavailable or unconfirmed; reconcile a dispatched operation before retrying."]
            trace?.record(phase,attempted:attempted,outcome:attempted ? "uncertain" : "failed")
        }
        if let data = try? JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys) { FileHandle.standardOutput.write(data + Data([10])) }
    }
    /// Request-in/result-out worker seam used by `main`; every external resource comes from `environment`.
    @MainActor static func perform(input: Data, environment: NativeWorkerEnvironment = .production) async -> [String:Any] {
        var attempted = false, phase = "operating_mode"
        var trace: NativeActionTrace?
        var receipt: [String:Any]
        do {
        let request = try JSONDecoder().decode(NativeRequest.self,from:input)
        trace = NativeActionTrace(request)
        if request.method == "status" {
            let backend: BBCJSONValue = OperatingMode.current == .readOnly ? .object(["ready":.bool(false),"reason":.string("read_only_mode"),"capabilities":.array([])]) : await Task.detached { Self.bridgeStatus(environment) }.value
            let ready = backend.object?["ready"]?.bool == true
            let methods = backend.object?["capabilities"] ?? .array([])
            receipt = ["ok":true,"adapter":"bbc-native-1","native_ready":ready,"backend":try JSONSerialization.jsonObject(with:JSONEncoder().encode(backend)),"methods":try JSONSerialization.jsonObject(with:JSONEncoder().encode(methods))]
            receipt["methods"] = (receipt["methods"] as? [String] ?? []) + ["read.status"] + (LocalModels.ready ? ["media.transcribe","media.visual"] : ["media.visual"])
        } else {
            phase = "request_validation"
            let parameters = try request.validated(), guid = parameters.message_guid!
            phase = "database_open"
            let database = try MessagesDatabase(url:environment.databaseURL)
            phase = "message_identity"
            try database.verify(chat:parameters.chat_guid,message:guid)
            phase = "native_preparation"
            if request.method == "read.status" {
                let unread = try database.unread(chat:parameters.chat_guid)
                receipt = ["ok":true,"observation_only":true,"chat_guid":parameters.chat_guid,"message_guid":guid,"target_read":!unread.contains(guid),"native_unread_count":unread.count]
            } else if ["media.visual","media.transcribe"].contains(request.method) {
                let lock = try NativeOperationLock(name:"media.lock",directory:environment.lockDirectory); defer { lock.release() }
                if request.method == "media.visual" {
                    phase = "visual_preparation"
                    let attachment = try database.visualAttachment(chat:parameters.chat_guid,message:guid,attachment:parameters.attachment_guid!)
                    receipt = try await LocalVisualMedia.prepare(attachment).packet
                } else {
                    phase = "audio_transcription"
                    receipt = try await LocalTranscription.transcribe(database.audioAttachment(chat:parameters.chat_guid,message:guid,attachment:parameters.attachment_guid!))
                }
                receipt["chat_guid"] = parameters.chat_guid; receipt["message_guid"] = guid; receipt["attachment_guid"] = parameters.attachment_guid!
            } else {
                let lock = try NativeOperationLock(name:"automation.lock",directory:environment.lockDirectory); defer { lock.release() }
                if ["read","reply","link"].contains(request.method) {
                    guard Set(try database.unread(chat:parameters.chat_guid)).isSubset(of:Set(parameters.read_guids!)) else { throw ActionFailure.invalid }
                }
                // Resolve the requested anchor's root before any native mutation.
                // Missing or malformed metadata must not turn a dispatch into an avoidable uncertain send.
                let replyRoot = request.method == "reply" ? try database.threadRoot(chat:parameters.chat_guid,message:guid) : nil
                let before = try database.maximumRowID()
                var fields = try JSONDecoder().decode(BBCJSONValue.self,from:input).object?["params"]?.object ?? [:]
                fields["method"] = .string(request.method)
                if request.method == "reply" { fields["message_guid"] = .string(guid) }
                if request.method == "link" { fields["text"] = .string(parameters.url!) }
                if request.method == "tapback" {
                    fields["associated_message_guid"] = .string(try database.reactionReference(chat:parameters.chat_guid,message:guid))
                }
                phase = "native_dispatch"
                let packet = BBCJSONValue.object(fields)
                let native = try await Task.detached { try NativeBridgeClient.request(packet,endpoint:environment.endpoint,timeout:environment.bridgeTimeout) }.value
                if native.object?["ok"]?.bool != true {
                    receipt = try JSONSerialization.jsonObject(with:JSONEncoder().encode(native)) as? [String:Any] ?? ["ok":false,"uncertain":true]
                } else {
                    attempted = true; phase = "native_confirmation"
                    if request.method == "read" {
                        try await confirm(environment) { try database.unread(chat:parameters.chat_guid).isEmpty }
                        receipt = ["ok":true,"chat_guid":parameters.chat_guid,"confirmation":"local-chat-read","sender_receipt":"unconfirmed"]
                    } else {
                        guard let sent = native.object?["guid"]?.string, UUID(uuidString:sent) != nil else { throw ActionFailure.uncertain }
                        if request.method == "tapback" {
                            try await confirm(environment) { try database.confirmedNativeReaction(chat:parameters.chat_guid,target:guid,sent:sent,reaction:parameters.reaction!,remove:parameters.remove ?? false,after:before) }
                            receipt = ["ok":true,"guid":sent,"chat_guid":parameters.chat_guid,"message_guid":guid,"reaction":parameters.reaction!,"remove":parameters.remove ?? false,"confirmation":"local-database"]
                        } else if request.method == "reply" {
                            guard let root = replyRoot else { throw ActionFailure.uncertain }
                            try await confirm(environment) { try database.confirmedReply(chat:parameters.chat_guid,root:root,text:parameters.text!,sent:sent,after:before) }
                            receipt = ["ok":true,"guid":sent,"chat_guid":parameters.chat_guid,"reply_to_guid":guid,"thread_root_guid":root,"confirmation":"local-database"]
                        } else {
                            try await confirm(environment) { try database.confirmedLink(chat:parameters.chat_guid,text:parameters.url!,after:before) == sent }
                            receipt = ["ok":true,"guid":sent,"chat_guid":parameters.chat_guid,"url":parameters.url!,"preview":"managed-by-messages","confirmation":"local-database"]
                        }
                    }
                }
            }
        }
        } catch {
            if let failure = error as? ActionFailure, failure == .uncertain { attempted = true }
            receipt = ["ok":false,"uncertain":attempted,"failure_code":phase,"error":"Native action unavailable or unconfirmed; reconcile a dispatched operation before retrying."]
            trace?.record(phase,attempted:attempted,outcome:attempted ? "uncertain" : "failed")
        }
        return receipt
    }
    nonisolated static func bridgeStatus(_ environment: NativeWorkerEnvironment) -> BBCJSONValue {
        if environment.endpoint == nil { return NativeBridgeClient.status() }
        return (try? NativeBridgeClient.request(.object(["method":.string("bridge.status")]),endpoint:environment.endpoint,timeout:environment.bridgeTimeout)) ?? .object(["ready":.bool(false),"reason":.string("native_bridge_not_started"),"capabilities":.array([])])
    }
    @MainActor static func confirm(_ environment: NativeWorkerEnvironment = .production, _ predicate: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(environment.confirmationTimeout)
        repeat { if try predicate() { return }; try await Task.sleep(for:.milliseconds(environment.confirmationInterval)) } while Date() < deadline
        throw ActionFailure.uncertain
    }
}

extension MessagesDatabase {
    func reactionReference(chat: String, message: String) throws -> String {
        try verify(chat:chat,message:message)
        let column = try optionalMessageColumn("balloon_bundle_id")
        let matches = try rows("""
            SELECT \(column) FROM message m
            JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id
            WHERE m.guid=?1 AND c.guid=?2 LIMIT 2
            """,[message,chat])
        guard matches.count == 1 else { throw ActionFailure.invalid }
        return (matches[0][0].isEmpty ? "p:0/" : "bp:") + message
    }

    func confirmedNativeReaction(chat: String, target: String, sent: String, reaction: String, remove: Bool, after: Int64) throws -> Bool {
        let index = NativeRequest.reactions.firstIndex(of:reaction)
        let type = (remove ? 3000 : 2000) + (index ?? 6)
        let emoji = try optionalMessageColumn("associated_message_emoji")
        let matches = try rows("""
            SELECT m.associated_message_guid,\(emoji) FROM message m
            JOIN chat_message_join j ON j.message_id=m.ROWID JOIN chat c ON c.ROWID=j.chat_id
            WHERE m.guid=?1 AND c.guid=?2 AND m.ROWID>CAST(?3 AS INTEGER)
            AND m.is_from_me=1 AND m.service='iMessage' AND m.associated_message_type=CAST(?4 AS INTEGER)
            AND m.is_sent=1 AND COALESCE(m.error,0)=0 LIMIT 2
            """,[sent,chat,String(after),String(type)])
        return matches.count == 1 && normalizedGUID(matches[0][0]) == target && (index != nil || matches[0][1] == reaction)
    }
}
