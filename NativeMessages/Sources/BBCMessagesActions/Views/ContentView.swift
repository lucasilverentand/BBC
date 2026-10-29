import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("apiPort") private var port = 7861
    @AppStorage("startAPIOnLaunch") private var startAPIOnLaunch = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("allowNetwork") private var allowNetwork = false
    @State private var keyName = ""
    @State private var newKey: String?
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.largeTitle).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blue Bubble Club").font(.title2.bold())
                        Text("Your Mac. Your Messages. Your API.").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                LabeledContent("API", value: model.running ? "Running" : model.starting ? "Starting…" : "Stopped")
                TextField("Port", value: $port, format: .number.grouping(.never)).disabled(model.running || model.starting)
                Toggle("Allow connections from other devices", isOn: $allowNetwork).disabled(model.running || model.starting)
                Text("http://\(allowNetwork ? "your-mac" : "127.0.0.1"):\(String(port))/v1").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text(allowNetwork ? "Use a trusted private network or your own HTTPS proxy. BBC does not configure remote access." : "Only this Mac can connect. Every request requires an API key.").font(.caption).foregroundStyle(.secondary)
                Button(model.running || model.starting ? "Stop API" : "Start API") {
                    if model.running || model.starting { model.stop() } else { model.start(port: port, allowNetwork: allowNetwork) }
                }.buttonStyle(.borderedProminent).disabled(model.keys.isEmpty && !model.running)
            }
            Section("Startup") {
                Toggle("Start at login", isOn: Binding(get: { model.startAtLogin || model.loginNeedsApproval }, set: { value in Task { await model.setStartAtLogin(value) } })).disabled(model.updatingLogin)
                Toggle("Start API when the app opens", isOn: $startAPIOnLaunch)
                Text("The app starts after you sign into this Mac, when Messages can use your account.").font(.caption).foregroundStyle(.secondary)
                if model.loginNeedsApproval {
                    Button("Approve in Login Items…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                }
            }
            Section("API keys") {
                ForEach(model.keys) { key in
                    HStack {
                        VStack(alignment: .leading) { Text(key.name); Text(key.createdAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Revoke", role: .destructive) { model.revoke(key.id) }
                    }
                }
                HStack {
                    TextField("Key name, e.g. Seven", text: $keyName)
                    Button("Create key") { if let value = model.createKey(name: keyName) { newKey = value; keyName = "" } }.disabled(keyName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Keys allow messaging through this Mac. Their hashes stay on this Mac; each secret is shown once.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Messages permissions") {
                Text("Sign into Messages in this macOS account. Allow Full Disk Access, Accessibility and Automation for Blue Bubble Club.").font(.callout)
                HStack {
                    Button("Accessibility") { model.requestAccessibility() }
                    Button("Automation") { Task { await model.requestAutomation() } }
                    Button("Privacy settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!) }
                    Button("API guide") { NSWorkspace.shared.open(URL(string: "https://github.com/lucasilverentand/BBC/blob/main/docs/api.md")!) }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
        }.formStyle(.grouped)
        .task { model.appOpened(); model.refreshLoginItem() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshLoginItem() } }
        .sheet(isPresented: Binding(get: { newKey != nil }, set: { if !$0 { newKey = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Save your API key").font(.title2.bold())
                Text("This is the only time the secret is shown. Store it in your client's secret settings.")
                Text(newKey ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(newKey ?? "", forType: .string) }
                    Spacer(); Button("Done") { newKey = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 460)
        }
    }
}
