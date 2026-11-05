import SwiftUI
import AppKit

struct SettingsPage: View {
    @Bindable var model: AppModel
    @AppStorage("startAPIOnLaunch") private var startAPI = false
    @AppStorage("apiPort") private var port = 7861
    @AppStorage(NativeMessagesStartup.hiddenLaunchKey) private var openMessagesHidden = false
    private var active: Bool { model.running || model.starting }
    var body: some View {
        Form {
            Section("Server") {
                TextField("Port", value: $port, format: .number.grouping(.never)).disabled(active)
                Text("http://127.0.0.1:\(String(port))/v1")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if active { Text("Stop the API to edit.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Startup") {
                Toggle("Start at login",isOn:Binding(get:{ model.startAtLogin || model.loginNeedsApproval },set:{ value in Task { await model.setStartAtLogin(value) } })).disabled(model.updatingLogin)
                Toggle("Start API at launch",isOn:$startAPI)
                Toggle("Open Messages hidden at launch",isOn:$openMessagesHidden)
                Text("Opens Messages in the background when BBC launches and hides Messages after BBC restarts it to connect native messaging.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.loginNeedsApproval {
                    Button("Approve in Login Items…") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                }
            }
        }.formStyle(.grouped)
    }
}

struct ServerPage: View {
    @Bindable var model: AppModel
    @AppStorage("startNativeBridgeOnLaunch") private var startNative = false
    var body: some View {
        Form {
            Section("API") {
                LabeledContent("Status", value: model.running ? "Running" : model.starting ? "Starting…" : "Stopped")
                APIControlButton(model: model)
            }
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    PermissionChecklistView(model: model)
                    if model.mode == .full {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: model.nativeConnected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.nativeConnected ? Color.green : Color.secondary)
                                .font(.title3)
                                .accessibilityLabel(model.nativeConnected ? "Connected" : "Not connected")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Native messaging").fontWeight(.medium)
                                Text(model.nativeStarting ? "Connecting…" : model.nativeConnected ? "Connected" : "Connect to enable message actions.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button(model.nativeConnected ? "Disconnect" : "Connect") {
                                if model.nativeConnected { model.stopNativeBridge() }
                                else { model.startNativeBridge() }
                            }.controlSize(.small).disabled(model.nativeStarting)
                        }
                        Toggle("Connect automatically at launch", isOn: $startNative)
                    }
                }
                Link("Setup guide", destination: AppBrand.setupGuideURL)
            } header: {
                HStack {
                    Text("Setup")
                    Spacer()
                    Button {
                        model.refreshPermissions()
                        model.refreshNativeBridge()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Recheck setup")
                    .accessibilityLabel("Recheck setup")
                }
            }
        }.formStyle(.grouped)
    }
}
