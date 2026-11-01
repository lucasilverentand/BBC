import SwiftUI

struct APIControlButton: View {
    @Bindable var model: AppModel
    @AppStorage("apiPort") private var port = 7861
    @AppStorage("allowNetwork") private var allowNetwork = false
    var body: some View {
        Button(model.running || model.starting ? "Stop API" : "Start API") {
            if model.running || model.starting { model.stop() }
            else { model.start(port:port,allowNetwork:allowNetwork) }
        }.buttonStyle(.borderedProminent).disabled(model.keys.isEmpty && !model.running && !model.starting)
    }
}

struct OverviewPage: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                HStack(spacing:16) {
                    Image(nsImage:AppBrand.icon).resizable().scaledToFit().frame(width:64,height:64)
                    VStack(alignment:.leading,spacing:4) {
                        Text("Blue Bubble Club").font(.title2.bold())
                        Text("Your Mac. Your Messages. Your API.").foregroundStyle(.secondary)
                    }
                }.padding(.vertical,8)
            }
            Section("This account") {
                LabeledContent("API",value:model.running ? "Running" : model.starting ? "Starting…" : "Stopped")
                LabeledContent("Mode",value:model.mode.title)
                LabeledContent("API keys",value:String(model.keys.count))
                LabeledContent("Permissions",value:"\(model.grantedPermissionCount) of \(model.permissionSteps.count) ready")
                APIControlButton(model:model)
            }
            Section("Native messaging") { Text(model.nativeRequirements).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

struct APIServerPage: View {
    @Bindable var model: AppModel
    @AppStorage("apiPort") private var port = 7861
    @AppStorage("allowNetwork") private var allowNetwork = false
    @AppStorage("allowedClientNetworks") private var allowedClients = ""
    private var active: Bool { model.running || model.starting }
    private var invalid: Bool { (try? IPNetwork.parseList(allowedClients)) == nil }
    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Status",value:model.running ? "Running" : model.starting ? "Starting…" : "Stopped")
                Picker("Account mode",selection:Binding(get:{ model.mode },set:{ model.setMode($0) })) {
                    ForEach(OperatingMode.allCases) { Text($0.title).tag($0) }
                }.disabled(active || model.nativeStarting)
                Text("Account mode limits every key. A full-access key cannot send while this account is read-only.").font(.caption).foregroundStyle(.secondary)
                APIControlButton(model:model).disabled(invalid && !active)
            }
            Section("Connection") {
                TextField("Port",value:$port,format:.number.grouping(.never)).disabled(active)
                Toggle("Allow connections from other devices",isOn:$allowNetwork).disabled(active)
                Text("http://\(allowNetwork ? "your-mac" : "127.0.0.1"):\(String(port))/v1").font(.system(.body,design:.monospaced)).textSelection(.enabled)
                Text("Use a different port for each macOS user. For remote access, use a trusted network or your own HTTPS proxy.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Allowed clients") {
                Text("Allow specific IP addresses or network ranges. Leave empty to allow any address that can reach the listener; every request still needs a key.").foregroundStyle(.secondary)
                TextEditor(text:$allowedClients).font(.system(.body,design:.monospaced)).frame(minHeight:110).disabled(active)
                    .accessibilityLabel("Allowed client IP addresses and CIDR ranges")
                Text("One per line, for example 192.168.1.20, 192.168.1.0/24 or ::1.").font(.caption).foregroundStyle(.secondary)
                if invalid { Label("Enter valid IPv4/IPv6 addresses or CIDR ranges.",systemImage:"exclamationmark.triangle").foregroundStyle(.red) }
                Text("BBC checks the direct connection address. Behind a proxy, allow the proxy's address; forwarded headers do not change this check.").font(.caption).foregroundStyle(.secondary)
            }
            if active { Text("Stop the API before changing its connection settings.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}
