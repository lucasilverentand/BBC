import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case overview = "Overview", api = "API Server", keys = "API Keys", permissions = "Permissions", native = "Native Messaging", startup = "Startup"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .api: "network"
        case .keys: "key"
        case .permissions: "checklist"
        case .native: "message"
        case .startup: "power"
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var page: AppPage? = .overview
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationSplitView {
            List(selection:$page) {
                Section("Blue Bubble Club") {
                    ForEach([AppPage.overview,.api,.keys]) { item in Label(item.rawValue,systemImage:item.symbol).tag(item) }
                }
                Section("Settings") {
                    ForEach([AppPage.permissions,.native,.startup]) { item in Label(item.rawValue,systemImage:item.symbol).tag(item) }
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
                switch page ?? .overview {
                case .overview: OverviewPage(model:model)
                case .api: APIServerPage(model:model)
                case .keys: APIKeysPage(model:model)
                case .permissions: PermissionsPage(model:model)
                case .native: NativeMessagingPage(model:model)
                case .startup: StartupPage(model:model)
                }
            }.navigationTitle((page ?? .overview).rawValue)
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
