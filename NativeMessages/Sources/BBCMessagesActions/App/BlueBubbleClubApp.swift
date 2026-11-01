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
            ContentView(model: model).frame(minWidth: 760, minHeight: 540)
        }.defaultSize(width: 920, height: 680)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
