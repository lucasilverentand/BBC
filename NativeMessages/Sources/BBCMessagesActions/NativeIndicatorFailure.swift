import Foundation
import OSLog
@preconcurrency import IMessage

enum NativeIndicatorFailure {
    static let phases: Set<String> = Set(["typing_input", "typing_validation", "typing_snapshot", "typing_lock", "typing_control", "typing_startup", "typing_permissions", "typing_adapter", "typing_scope", "typing_start", "typing_wait", "typing_cleanup", "typing_started", "typing_stopped", "typing_stopped_before_start"] + BBCNativeTypingFailure.allCases.map { "typing_start_" + $0.rawValue })
    static let controllerPhases: Set<String> = ["accessibility", "coordination", "discovery", "ownership", "launch", "window", "responsiveness"].reduce(into: []) { $0.insert("typing_controller_" + $1) }
    static func label(_ phase: String) -> String { phases.contains(phase) || controllerPhases.contains(phase) ? phase : "typing_unknown" }
    static func resolve(_ error: Error, phase: String, attempted: Bool) -> (phase: String, attempted: Bool) {
        if phase == "typing_start", let native = error as? BBCNativeTypingFailure {
            return ("typing_start_" + native.rawValue, attempted)
        }
        if phase == "typing_start", let controller = error as? BBCNativeControllerFailure {
            return ("typing_controller_" + controller.rawValue, false)
        }
        return (label(phase), attempted)
    }
    static func record(phase: String, attempted: Bool) {
        let fixed = label(phase)
        Logger(subsystem: "club.bluebubble.transport", category: "NativeMessagesUI").notice("Native indicator stage: \(fixed, privacy: .public); attempted=\(attempted, privacy: .public)")
    }
}
