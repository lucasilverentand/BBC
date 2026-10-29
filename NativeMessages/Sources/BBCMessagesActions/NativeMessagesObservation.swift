import AppKit
import ApplicationServices
import Darwin
import OSLog

/// Bounded observations only. Never returns titles, text, identifiers or handles.
@MainActor enum NativeMessagesObservation {
    struct Snapshot: Codable, Equatable {
        var processFound = false
        var hidden: Bool?
        var active: Bool?
        var windowsStatus: Int32?
        var windowCount: Int?
        var mainWindowStatus: Int32?
        var focusedWindowStatus: Int32?
        var menuBarStatus: Int32?
        var storedWindowCoordination: Bool?
        var sectionWindows = 0
        var sectionEntries = 0
        var sectionFailure: Int32?
        var conversationLists = 0
        var selectedConversations: Int?
        var composeFields = 0
        var textAreas = 0
        var tables = 0
        var outlines = 0
        var scrollAreas = 0
        var sheets = 0
        var groups = 0
        var buttons = 0
        var staticTexts = 0
        var images = 0
        var visited = 0
        var scanComplete = false
    }

    static func inspect() -> Snapshot {
        guard geteuid() != 0 && geteuid() == getuid(), let owned = NativeMessagesStartup.current(), owned.uid == getuid(),
              let app = NSRunningApplication(processIdentifier: owned.pid),
              app.bundleIdentifier == "com.apple.MobileSMS" else { return Snapshot() }
        var result = Snapshot()
        result.processFound = true; result.hidden = app.isHidden; result.active = app.isActive
        result.storedWindowCoordination = UserDefaults(suiteName: "club.bluebubble.messages-actions")?.object(forKey: "BEEPWindowCoordination") as? Bool
        let root = AXUIElementCreateApplication(owned.pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        func attribute(_ node: AXUIElement, _ name: CFString) -> (AXError, CFTypeRef?) {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, name, &value)
            return (status, value)
        }
        let windows = attribute(root, kAXWindowsAttribute as CFString)
        result.windowsStatus = windows.0.rawValue
        var nodes = windows.1 as? [AXUIElement] ?? []
        if windows.0 == .success { result.windowCount = nodes.count }
        let main = attribute(root, kAXMainWindowAttribute as CFString)
        let focused = attribute(root, kAXFocusedWindowAttribute as CFString)
        result.mainWindowStatus = main.0.rawValue; result.focusedWindowStatus = focused.0.rawValue
        for value in [main.1, focused.1].compactMap({ $0 }) where CFGetTypeID(value) == AXUIElementGetTypeID() {
            let node = unsafeDowncast(value, to: AXUIElement.self)
            if !nodes.contains(where: { CFEqual($0, node) }) { nodes.append(node) }
        }
        result.menuBarStatus = attribute(root, kAXMenuBarAttribute as CFString).0.rawValue
        // Messages exposes a direct section index. Prefer it over traversing
        // hundreds of transcript rows before reaching the sidebar/editor.
        var sections: [AXUIElement] = []
        var sectionTruncated = false
        for window in nodes.prefix(16) {
            let (status, value) = attribute(window, "AXSections" as CFString)
            guard status == .success, let entries = value as? [[String: CFTypeRef]] else {
                result.sectionFailure = status.rawValue; continue
            }
            result.sectionWindows += 1; result.sectionEntries += entries.count
            sectionTruncated = sectionTruncated || entries.count > 32
            for entry in entries.prefix(32) {
                guard let object = entry["SectionObject"], CFGetTypeID(object) == AXUIElementGetTypeID() else { continue }
                let section = unsafeDowncast(object, to: AXUIElement.self)
                if !sections.contains(where: { CFEqual($0, section) }) { sections.append(section) }
            }
        }
        var queue = Array((sections + Array(nodes.prefix(16))).prefix(200)).map { ($0, 0) }, index = 0
        var truncated = nodes.count > 16 || sections.count + min(nodes.count, 16) > 200 || sectionTruncated
        let until = ProcessInfo.processInfo.systemUptime + 0.5
        while index < queue.count, result.visited < 200, ProcessInfo.processInfo.systemUptime < until {
            let (node, depth) = queue[index]; index += 1; result.visited += 1
            if let id = attribute(node, kAXIdentifierAttribute as CFString).1 as? String {
                if ["ConversationList", "CKConversationListCollectionView"].contains(id) {
                    result.conversationLists += 1
                    let selection = attribute(node, kAXSelectedChildrenAttribute as CFString)
                    let count = (selection.1 as? [AXUIElement])?.count ?? (selection.0 == .noValue ? 0 : nil)
                    if let count {
                        if let prior = result.selectedConversations, prior != count { result.selectedConversations = -1 }
                        else { result.selectedConversations = count }
                    }
                }
                if id == "messageBodyField" { result.composeFields += 1 }
            }
            switch attribute(node, kAXRoleAttribute as CFString).1 as? String {
            case kAXTextAreaRole: result.textAreas += 1
            case kAXTableRole: result.tables += 1
            case kAXOutlineRole: result.outlines += 1
            case kAXScrollAreaRole: result.scrollAreas += 1
            case kAXSheetRole: result.sheets += 1
            case kAXGroupRole: result.groups += 1
            case kAXButtonRole: result.buttons += 1
            case kAXStaticTextRole: result.staticTexts += 1
            case kAXImageRole: result.images += 1
            default: break
            }
            if let children = attribute(node, kAXChildrenAttribute as CFString).1 as? [AXUIElement] {
                let remaining = max(0, 200 - queue.count)
                if depth >= 8 || children.count > remaining { truncated = truncated || !children.isEmpty }
                if depth < 8 { queue += children.prefix(remaining).map { ($0, depth + 1) } }
            }
        }
        result.scanComplete = index == queue.count && !truncated
        return result
    }

    static func record() {
        let snapshot = inspect()
        guard let data = try? JSONEncoder().encode(snapshot), let line = String(data: data, encoding: .utf8) else { return }
        Logger(subsystem: "club.bluebubble.transport", category: "NativeMessagesUI").notice("Native Messages observation: \(line, privacy: .public)")
    }
}
