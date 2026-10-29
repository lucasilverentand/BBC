import Foundation
import OSLog
import CryptoKit

/// Fixed stages and opaque operation IDs only; never encode native request data.
struct NativeActionTrace {
    let id: UUID
    let action: String
    let sourceKey: String?
    private let spanID = UUID()
    private let began = DispatchTime.now().uptimeNanoseconds
    private static let logger = Logger(subsystem: "club.bluebubble.transport", category: "NativeMessagesTrace")
    static let readStages: Set<String> = ["read_snapshot", "read_open", "read_unhide_requested", "read_unhide_accepted", "read_already_unhidden", "read_submit", "read_submitted", "read_confirmation"]
    static let stages = readStages.union(NativeIndicatorFailure.phases).union(NativeIndicatorFailure.controllerPhases).union(["received", "receipt", "reply_ui", "reply_confirmation", "typing_cleanup_returned"])

    init?(_ request: NativeRequest) {
        guard let raw = request.trace_id, let id = UUID(uuidString: raw),
              ["read", "read.status", "reply", "typing.start"].contains(request.method) else { return nil }
        self.id = id; action = request.method
        if let params = request.params, let guid = params.message_guid, UUID(uuidString: guid) != nil,
           let data = try? JSONSerialization.data(withJSONObject: [params.chat_guid, guid.uppercased()], options: [.withoutEscapingSlashes]) {
            sourceKey = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else { sourceKey = nil }
    }

    func record(_ stage: String, attempted: Bool, outcome: String? = nil, error: Error? = nil) {
        guard let line = line(stage, attempted: attempted, outcome: outcome, error: error) else { return }
        Self.logger.notice("Native Messages trace: \(line, privacy: .public)")
    }

    func line(_ stage: String, attempted: Bool, outcome: String? = nil, error: Error? = nil) -> String? {
        // The native adapter preserves a changed draft/selection. Its successful
        // stop return is not proof that the owned placeholder was cleared.
        let observedStage = stage == "typing_stopped" ? "typing_cleanup_returned" : stage
        var event: [String: Any] = ["version": 1, "source": "native", "traceID": id.uuidString, "spanID": spanID.uuidString,
            "action": action, "stage": Self.stages.contains(observedStage) ? observedStage : "native_failure", "attempted": attempted,
            "elapsedMS": (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000]
        if let sourceKey { event["sourceKey"] = sourceKey }
        if let outcome, ["native-confirmed", "observation-only", "uncertain", "failed", "unconfirmed"].contains(outcome) {
            event["outcome"] = outcome; event["senderVisibility"] = "unobserved"
        }
        if let error {
            let value = error as NSError
            if value.domain == NSOSStatusErrorDomain, [-1743, -1712, -600, -609, -128].contains(value.code) { event["osStatus"] = value.code }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
