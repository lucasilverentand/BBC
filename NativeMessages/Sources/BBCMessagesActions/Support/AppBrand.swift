import AppKit

@MainActor enum AppBrand {
    static var icon: NSImage {
        if let icon = Bundle.main.image(forResource: "AppIcon") { return icon }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    }
}
