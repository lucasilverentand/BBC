import Foundation
import AppKit
import ApplicationServices
import CoreServices
import Darwin
@preconcurrency import IMessage

struct BBCMessagesActions {
    @MainActor static func main() async {
        var receipt: [String: Any] = ["ok": false, "uncertain": true]
        var attempted = false
        var phase = "runtime_user"
        var diagnostics: [String: Any] = [:]
        var trace: NativeActionTrace?
        do {
            guard getuid() != 0, getuid() == geteuid() else { throw ActionFailure.invalid }
            phase = "request_input"
            if CommandLine.arguments.contains("--typing-session") {
                try await NativeTypingSession.run(initialize: initialize, decoded: { trace = NativeActionTrace($0) }, progress: {
                    phase = $0; attempted = $1; trace?.record($0, attempted: $1)
                })
                return
            }
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
                guard input.count + chunk.count <= 65536 else { throw ActionFailure.invalid }
                input.append(chunk)
            }
            let request = try JSONDecoder().decode(NativeRequest.self, from: input)
            trace = NativeActionTrace(request); trace?.record("received", attempted: false)
            phase = "database_access"
            let database = try MessagesDatabase(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"))
            let ax = AXIsProcessTrusted()
            let automationStatus = NativeMessagesStartup.automationStatus()
            let automation = automationStatus == noErr
            if request.method == "status" {
                NativeMessagesObservation.record()
                var methods = ax && automation ? ["tapback", "read", "reply", "link", "typing"] : []
                methods.append("media.visual")
                if LocalModels.ready { methods.append("media.transcribe") }
                receipt = ["ok": true, "accessibility": ax, "automation": automation,
                           "methods": methods, "adapter": "beeper-bbc-1", "automation_status": automationStatus,
                           "messages_running": NativeMessagesStartup.current() != nil]
            } else if request.method == "media.transcribe" {
                phase = "audio_target"
                let p = try request.validated()
                let attachment = try database.audioAttachment(chat: p.chat_guid, message: p.message_guid!, attachment: p.attachment_guid!)
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BBCMessagesActions", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                phase = "audio_lock"
                let lock = open(directory.appendingPathComponent("media.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
                guard lock >= 0 else { throw ActionFailure.unavailable }
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ActionFailure.busy }
                defer { flock(lock, LOCK_UN) }
                phase = "audio_transcription"
                receipt = try await LocalTranscription.transcribe(attachment)
                receipt["chat_guid"] = p.chat_guid; receipt["message_guid"] = p.message_guid!
                receipt["attachment_guid"] = p.attachment_guid!
            } else if request.method == "media.visual" {
                phase = "visual_target"
                let p = try request.validated()
                let attachment = try database.visualAttachment(chat: p.chat_guid, message: p.message_guid!, attachment: p.attachment_guid!)
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BBCMessagesActions", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                phase = "visual_lock"
                let lock = open(directory.appendingPathComponent("media.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
                guard lock >= 0 else { throw ActionFailure.unavailable }
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ActionFailure.busy }
                defer { flock(lock, LOCK_UN) }
                phase = "visual_preparation"
                receipt = try await LocalVisualMedia.prepare(attachment).packet
                receipt["chat_guid"] = p.chat_guid; receipt["message_guid"] = p.message_guid!
                receipt["attachment_guid"] = p.attachment_guid!
            } else {
                phase = "system_permissions"
                guard request.method == "read.status" || ax else { throw ActionFailure.unavailable }
                phase = "request_validation"
                let p = try request.validated(), guid = p.message_guid!
                phase = "automation_lock"
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BBCMessagesActions", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let lock = open(directory.appendingPathComponent("automation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
                guard lock >= 0 else { throw ActionFailure.unavailable }
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ActionFailure.busy }
                defer { flock(lock, LOCK_UN) }
                phase = "target_identity"
                try database.verify(chat: p.chat_guid, message: guid)
                if request.method == "read.status" {
                    // Observation only: no bootstrap, activation, Apple Events or UI action.
                    let unread = try database.unread(chat: p.chat_guid)
                    receipt = ["ok": true, "observation_only": true, "chat_guid": p.chat_guid,
                               "message_guid": guid, "target_read": !unread.contains(guid), "native_unread_count": unread.count]
                } else if ["reply", "link"].contains(request.method) {
                    let unread = try database.unread(chat: p.chat_guid)
                    guard Set(unread).isSubset(of: Set(p.read_guids!)) else { throw ActionFailure.invalid }
                    let root = try database.threadRoot(chat: p.chat_guid, message: guid)
                    let before = try database.maximumRowID()
                    phase = "messages_startup"
                    let pid = try await NativeMessagesStartup.ensureRunning()
                    phase = "system_permissions"
                    guard NativeMessagesStartup.automationStatus(pid: pid) == noErr else { throw ActionFailure.unavailable }
                    phase = "adapter_setup"
                    let api = try initialize(directory)
                    guard Set(try database.unread(chat: p.chat_guid)).isSubset(of: Set(p.read_guids!)) else { throw ActionFailure.invalid }
                    attempted = true; phase = request.method == "link" ? "link_ui" : "reply_ui"
                    trace?.record(phase, attempted: attempted)
                    let text = request.method == "link" ? p.url! : p.text!
                    if request.method == "link" { try await api.bbcSendLinkOnce(threadID: p.chat_guid, messageID: guid, url: text) }
                    else { try await api.bbcReplyOnce(threadID: p.chat_guid, messageID: guid, text: text) }
                    phase = request.method == "link" ? "link_confirmation" : "reply_confirmation"
                    trace?.record(phase, attempted: attempted)
                    var sent: String?
                    try await confirm { sent = request.method == "link"
                            ? try database.confirmedLink(chat: p.chat_guid, text: text, after: before)
                            : try database.confirmedReply(chat: p.chat_guid, root: root, text: text, after: before)
                        return sent != nil }
                    receipt = ["ok": true, "guid": sent!, "chat_guid": p.chat_guid, "confirmation": "local-database"]
                    if request.method == "reply" { receipt["reply_to_guid"] = guid; receipt["thread_root_guid"] = root }
                    else { receipt["url"] = text; receipt["preview"] = "managed-by-messages" }
                } else if request.method == "tapback" {
                    phase = "reaction_snapshot"
                    let reaction = p.reaction!
                    let nativeReaction = NativeRequest.reactions.firstIndex(of: reaction).map { NativeRequest.beeperReactions[$0] } ?? reaction
                    let remove = p.remove ?? false
                    if !remove, EmojiTapback.isDesired(current: try database.reactionValue(chat: p.chat_guid, message: guid), reaction: reaction, remove: false) {
                        receipt = ["ok": true, "unchanged": true, "message_guid": guid, "chat_guid": p.chat_guid]
                    } else {
                        phase = "messages_startup"
                        let pid = try await NativeMessagesStartup.ensureRunning()
                        phase = "system_permissions"
                        guard NativeMessagesStartup.automationStatus(pid: pid) == noErr else { throw ActionFailure.unavailable }
                        phase = "adapter_setup"
                        let api = try initialize(directory)
                        attempted = true
                        phase = "reaction_ui"
                        let nativeStateObserved = try await api.bbcSetReactionOnce(threadID: p.chat_guid, messageID: guid, reaction: nativeReaction, on: !remove)
                        phase = "reaction_confirmation"
                        if !nativeStateObserved {
                            guard !remove else { throw ActionFailure.uncertain }
                            try await confirm {
                                EmojiTapback.isDesired(current: try database.reactionValue(chat: p.chat_guid, message: guid), reaction: reaction, remove: remove)
                            }
                        }
                        receipt = ["ok": true, "message_guid": guid, "chat_guid": p.chat_guid, "reaction": p.reaction!, "remove": remove,
                                   "confirmation": nativeStateObserved ? "native-ui" : "local-database"]
                    }
                } else {
                    phase = "read_snapshot"
                    let unread = try database.unread(chat: p.chat_guid)
                    phase = "unconsumed_native_messages"
                    diagnostics = ["native_unread_count": unread.count, "outside_scope_count": Set(unread).subtracting(p.read_guids!).count]
                    if !Set(unread).isSubset(of: Set(p.read_guids!)) {
                        diagnostics["outside_scope_metadata"] = try database.unreadOutsideScope(chat: p.chat_guid, consumed: Set(p.read_guids!))
                    }
                    guard Set(unread).isSubset(of: Set(p.read_guids!)) else { throw ActionFailure.invalid }
                    if !unread.isEmpty {
                        phase = "messages_startup"
                        let pid = try await NativeMessagesStartup.ensureRunning()
                        phase = "system_permissions"
                        guard NativeMessagesStartup.automationStatus(pid: pid) == noErr else { throw ActionFailure.unavailable }
                        phase = "read_target"
                        let target = try NativeMessageRead.prepare(messageGUID: guid, pid: pid)
                        try await NativeMessageRead.perform(target, recheck: {
                            // Startup can suspend. Recheck exact identity and the
                            // complete unread set immediately before the one open.
                            try database.verify(chat: p.chat_guid, message: guid)
                            let current = try database.unread(chat: p.chat_guid)
                            phase = "unconsumed_native_messages"
                            diagnostics = ["native_unread_count": current.count, "outside_scope_count": Set(current).subtracting(p.read_guids!).count]
                            if !Set(current).isSubset(of: Set(p.read_guids!)) {
                                diagnostics["outside_scope_metadata"] = try database.unreadOutsideScope(chat: p.chat_guid, consumed: Set(p.read_guids!))
                            }
                            guard Set(current).isSubset(of: Set(p.read_guids!)) else { throw ActionFailure.invalid }
                            return !current.isEmpty
                        }, progress: { phase = $0; attempted = $1; trace?.record($0, attempted: $1) }, submit: { target in
                            try NativeMessageRead.submit(target, observation: { trace?.record($0, attempted: true) })
                        }) {
                            try await confirm {
                                try database.verify(chat: p.chat_guid, message: guid)
                                return try database.unread(chat: p.chat_guid).isEmpty
                            }
                        }
                    }
                    receipt = ["ok": true, "chat_guid": p.chat_guid, "confirmation": "local-chat-read", "sender_receipt": "unconfirmed"]
                }
            }
        } catch {
            if phase.hasPrefix("typing_") {
                NativeMessagesObservation.record()
                let failure = NativeIndicatorFailure.resolve(error, phase: phase, attempted: attempted)
                phase = failure.phase; attempted = failure.attempted
            }
            if let reaction = error as? BBCNativeReactionFailure {
                phase = "reaction_" + reaction.rawValue
                attempted = [.directAction, .apply].contains(reaction)
            }
            if phase.hasPrefix("reaction_") { NativeMessagesObservation.record() }
            if let controller = error as? BBCNativeControllerFailure {
                phase = "controller_" + controller.rawValue; attempted = false
            }
            if let reply = error as? BBCNativeReplyFailure {
                phase = "reply_" + reply.rawValue
                attempted = reply == .send
            }
            let readFailure = NativeReadFailureDisposition.resolve(error, phase: phase, attempted: attempted)
            phase = readFailure.phase; attempted = readFailure.attempted
            trace?.record(phase, attempted: attempted, outcome: attempted ? "uncertain" : "failed", error: error)
            // No localized errors, paths, handles, message text or credentials.
            receipt = diagnostics.merging(["ok": false, "uncertain": attempted, "failure_code": phase,
                                          "error": "Native Messages action not confirmed; reconcile before retrying."], uniquingKeysWith: { _, new in new })
            if phase.hasPrefix("typing_") {
                NativeIndicatorFailure.record(phase: phase, attempted: attempted)
            }
        }
        trace?.record("receipt", attempted: attempted, outcome: receipt["observation_only"] as? Bool == true ? "observation-only" : receipt["ok"] as? Bool == true ? "native-confirmed" : receipt["uncertain"] as? Bool == true ? "uncertain" : "failed")
        if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data([10]))
        }
    }
    @MainActor private static func initialize(_ directory: URL) throws -> PlatformAPI {
        NSApplication.shared.setActivationPolicy(.prohibited)
        IMessageHost.bootstrapWithOptions(dataDirPath: directory.path, verbose: false, useSecondaryInstance: false)
        return try PlatformAPI(accountID: "bbc-local")
    }
    @MainActor private static func confirm(_ predicate: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        throw ActionFailure.uncertain
    }
}
