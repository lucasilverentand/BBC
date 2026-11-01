import AppKit

@MainActor enum AppBrand {
    static let setupGuideURL = URL(string:"https://github.com/lucasilverentand/BBC/blob/main/docs/setup.md")!
    static let nativeSetupURL = URL(string:"https://github.com/lucasilverentand/BBC/blob/main/docs/setup.md#native-messaging")!
    static var icon: NSImage {
        if let icon = Bundle.main.image(forResource: "AppIcon") { return icon }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    }
}
