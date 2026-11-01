import SwiftUI
import AppKit

struct PermissionsPage: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Messages access") {
                PermissionChecklistView(model:model)
                Link("BBC setup guide",destination:AppBrand.setupGuideURL)
                HStack {
                    Button("Show setup helper") { model.showPermissionHelper() }
                    Button("Recheck") { model.refreshPermissions() }
                    Spacer(); Text("\(model.grantedPermissionCount) of \(model.permissionSteps.count) ready").foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}

struct NativeMessagingPage: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Connection to Messages") {
                Text(model.nativeRequirements).foregroundStyle(.secondary)
                HStack {
                    Button(model.nativeConnected ? "Stop native bridge" : "Start native bridge") {
                        if model.nativeConnected { model.stopNativeBridge() } else { model.startNativeBridge() }
                    }.disabled(model.nativeStarting || model.mode == .readOnly)
                    Button("Recheck") { model.refreshNativeBridge() }.disabled(model.nativeStarting)
                    Link("BBC setup guide",destination:AppBrand.nativeSetupURL)
                }
                Text("Starting the bridge restarts Messages gracefully. No drafts are cleared.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct StartupPage: View {
    @Bindable var model: AppModel
    @AppStorage("startAPIOnLaunch") private var startAPI = false
    @AppStorage("startNativeBridgeOnLaunch") private var startNative = false
    var body: some View {
        Form {
            Section("This macOS login") {
                Toggle("Start at login",isOn:Binding(get:{ model.startAtLogin || model.loginNeedsApproval },set:{ value in Task { await model.setStartAtLogin(value) } })).disabled(model.updatingLogin)
                Toggle("Start API when the app opens",isOn:$startAPI)
                Toggle("Start native messaging when the app opens",isOn:$startNative).disabled(model.mode == .readOnly)
                Text("BBC starts after this user signs in, when Messages can use their account.").font(.caption).foregroundStyle(.secondary)
                if model.loginNeedsApproval {
                    Button("Approve in Login Items…") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                }
            }
        }.formStyle(.grouped)
    }
}
