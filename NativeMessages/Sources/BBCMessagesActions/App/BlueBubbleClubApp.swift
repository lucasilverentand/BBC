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
    var body: some Scene {
        Window("Blue Bubble Club", id: "main") {
            ContentView(model: delegate.model).frame(minWidth: 760, minHeight: 540)
        }.defaultSize(width: 920, height: 680)
            .defaultLaunchBehavior(.suppressed)
            .commands {
                CommandGroup(replacing: .saveItem) {
                    APIStartStopCommand(model: delegate.model)
                }
                CommandMenu("Go") { PageNavigationMenu(model: delegate.model) }
                CommandGroup(replacing: .appSettings) {
                    SettingsShortcut(model: delegate.model)
                }
            }
        MenuBarExtra("Blue Bubble Club", systemImage: "message.fill") {
            MenuBarContent(model: delegate.model)
        }
    }
}

private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.running ? "API running" : model.starting ? "API starting…" : "API stopped")
        APIStartStopCommand(model: model)
        if model.error != nil {
            Button("View error…") { show(.server) }
        }
        Divider()
        PageNavigationMenu(model: model)
        Divider()
        Button("Quit Blue Bubble Club") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ page: AppPage) {
        model.selectedPage = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct APIStartStopCommand: View {
    let model: AppModel
    @AppStorage("apiPort") private var port = 7861

    var body: some View {
        Button(model.running || model.starting ? "Stop API" : "Start API") {
            if model.running || model.starting { model.stop() }
            else { model.start(port: port) }
        }.keyboardShortcut("s")
    }
}

private struct PageNavigationMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(AppPage.allCases) { page in
            Button("\(page.rawValue)…", systemImage: page.symbol) {
                model.selectedPage = page
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(page.shortcut)
        }
    }
}

private struct SettingsShortcut: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            model.selectedPage = .settings
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.appOpened()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.log.record("App quit.") }
}
