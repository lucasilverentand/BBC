import AppKit

@MainActor enum AppBrand {
    static var icon: NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) { return icon }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    }
}
