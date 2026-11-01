import Foundation

/// Per-login application policy. No HTTP request can change it.
enum OperatingMode: String, CaseIterable, Identifiable {
    case full = "full"
    case readOnly = "read-only"
    var id: String { rawValue }
    var title: String { self == .full ? "Full API" : "Read-only · watch and receive" }
    static var current: Self {
        let value = UserDefaults.standard.string(forKey:"operatingMode")
        // Preserve existing installations; unknown configured values fail closed.
        return value == nil ? .full : (Self(rawValue:value!) ?? .readOnly)
    }
    func allows(method: String) -> Bool {
        self == .full || Self.observerMethods.contains(method)
    }
    static let observerMethods: Set<String> = ["status","messages.after","messages.status","messages.search","media.download","read.status","media.visual","media.transcribe","webhooks.register","webhooks.list","webhooks.remove"]
}
