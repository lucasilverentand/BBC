import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case server = "Server", keys = "API Keys", logs = "Logs", settings = "Settings"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .server: "globe"
        case .keys: "key"
        case .logs: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationSplitView {
            List(selection:$model.selectedPage) {
                ForEach(AppPage.allCases) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }
            }.listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min:190,ideal:215,max:270)
            .safeAreaInset(edge:.bottom) {
                HStack(spacing:8) {
                    Circle().fill(model.running ? Color.green : Color.secondary).frame(width:7,height:7)
                    Text(model.running ? "API running" : model.starting ? "API starting…" : "API stopped")
                    Spacer()
                }.font(.caption).padding()
            }
        } detail: {
            Group {
                switch model.selectedPage ?? .server {
                case .server: ServerPage(model:model)
                case .keys: APIKeysPage(model:model)
                case .logs: LogsPage(log: model.log)
                case .settings: SettingsPage(model:model)
                }
            }.navigationTitle((model.selectedPage ?? .server).rawValue)
            .safeAreaInset(edge:.bottom) {
                if let error = model.error {
                    HStack {
                        Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.red)
                        Spacer(); Button("Dismiss") { model.error = nil }
                    }.font(.callout).padding().background(.bar)
                }
            }
        }
        .task { model.appOpened(); model.refreshLoginItem(); model.refreshPermissions(); model.refreshNativeBridge() }
        .onChange(of:scenePhase) { _,phase in
            if phase == .active { model.refreshLoginItem(); model.refreshPermissions(); model.refreshNativeBridge() }
        }
    }
}
