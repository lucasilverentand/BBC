import Foundation
import ApplicationServices
import SQLite3

struct PermissionStatus: Equatable {
    var fullDiskAccess = false
    var automation = false
    var messagesRunning = false
    var allGranted: Bool { fullDiskAccess && automation }
    var grantedCount: Int { [fullDiskAccess, automation].filter { $0 }.count }
    func granted(_ step: PermissionStep) -> Bool {
        switch step { case .fullDiskAccess: fullDiskAccess; case .automation: automation }
    }
    @MainActor static func current() -> Self {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")
        let disk = (try? MessagesDatabase(url: url).maximumRowID()) != nil
        return .init(fullDiskAccess: disk, automation: OperatingMode.current == .full && NativeMessagesStartup.automationStatus() == noErr, messagesRunning: NativeMessagesStartup.current() != nil)
    }
}

enum PermissionStep: String, CaseIterable, Identifiable {
    case fullDiskAccess, automation
    var id: Self { self }
    var title: String {
        switch self { case .fullDiskAccess: "Full Disk Access"; case .automation: "Messages Automation" }
    }
    var instruction: String {
        switch self {
        case .fullDiskAccess: "Add BBC in Settings and turn it on."
        case .automation: "Allow BBC to control Messages."
        }
    }
    var settingsURL: URL {
        switch self {
        case .fullDiskAccess: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        case .automation: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        }
    }
}
