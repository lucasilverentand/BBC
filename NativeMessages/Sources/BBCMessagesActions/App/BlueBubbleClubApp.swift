import SwiftUI
import AppKit

@main enum BlueBubbleClubMain {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--native-actions") { await BBCMessagesActions.main(); return }
        if CommandLine.arguments.contains("--rpc") { await LocalRPC.run(); return }
        BlueBubbleClubApp.main()
    }
}

struct BlueBubbleClubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("Blue Bubble Club", id: "main") {
            ContentView(model: model).frame(minWidth: 480, minHeight: 520)
        }.defaultSize(width: 540, height: 620)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppBrand.icon
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
