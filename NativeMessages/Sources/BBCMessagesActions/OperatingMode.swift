import Foundation

/// Access profiles shared by token authorization and internal routing.
enum OperatingMode: String, CaseIterable, Identifiable {
    case full = "full"
    case readOnly = "read-only"
    var id: String { rawValue }
    var title: String { self == .full ? "Full API" : "Read-only · watch and receive" }
    // Runtime access is authorized per API key. The former app preference is
    // migrated into key permissions when the app opens its store.
    static var current: Self { .full }
    func allows(method: String) -> Bool {
        self == .full || Self.observerMethods.contains(method)
    }
    static let observerMethods: Set<String> = ["status","messages.after","messages.status","messages.search","media.download","read.status","media.visual","media.transcribe","webhooks.register","webhooks.list","webhooks.remove"]
}
