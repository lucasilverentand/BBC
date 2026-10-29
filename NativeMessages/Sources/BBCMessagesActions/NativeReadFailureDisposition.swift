import Foundation
@preconcurrency import IMessage

/// Classify the scoped read boundary without leaking underlying AX/AppKit errors.
struct NativeReadFailureDisposition {
    let phase: String
    let attempted: Bool

    static func resolve(_ error: Error, phase: String, attempted: Bool) -> Self {
        if let read = error as? BBCNativeReadFailure {
            return .init(phase: "read_" + read.rawValue, attempted: read == .controller ? false : attempted)
        }
        if phase == "read_ui", let controller = error as? BBCNativeControllerFailure {
            return .init(phase: "read_controller_" + controller.rawValue, attempted: false)
        }
        return .init(phase: phase, attempted: attempted)
    }
}
