import Foundation
import ApplicationServices
import SQLite3

struct PermissionStatus: Equatable {
    var fullDiskAccess = false
    var accessibility = false
    var automation = false
    var messagesRunning = false
    var allGranted: Bool { fullDiskAccess && accessibility && automation }
    var grantedCount: Int { [fullDiskAccess, accessibility, automation].filter { $0 }.count }
    func granted(_ step: PermissionStep) -> Bool {
        switch step { case .fullDiskAccess: fullDiskAccess; case .accessibility: accessibility; case .automation: automation }
    }
    @MainActor static func current() -> Self {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        let disk = (try? MessagesDatabase(url: url).maximumRowID()) != nil
        return .init(fullDiskAccess: disk, accessibility: AXIsProcessTrusted(), automation: NativeMessagesStartup.automationStatus() == noErr, messagesRunning: NativeMessagesStartup.current() != nil)
    }
}

enum PermissionStep: String, CaseIterable, Identifiable {
    case fullDiskAccess, accessibility, automation
    var id: Self { self }
    var title: String {
        switch self { case .fullDiskAccess: "Full Disk Access"; case .accessibility: "Accessibility"; case .automation: "Messages Automation" }
    }
    var instruction: String {
        switch self {
        case .fullDiskAccess: "Drag the app into the list, then turn its switch on. This lets BBC read your Messages database."
        case .accessibility: "Add the app if needed, then turn its switch on. This enables native replies, Tapbacks and typing."
        case .automation: "Choose Allow when macOS asks BBC to control Messages. Messages must be signed in on this account."
        }
    }
    var settingsURL: URL {
        switch self {
        case .fullDiskAccess: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .automation: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        }
    }
}
