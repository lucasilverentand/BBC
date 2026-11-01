import SwiftUI
import AppKit

private struct KeyEditor: Identifiable {
    let id = UUID()
    let record: APIKeyRecord?
}

struct APIKeysPage: View {
    @Bindable var model: AppModel
    @State private var editor: KeyEditor?
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Give each integration its own key and access level.").foregroundStyle(.secondary)
                    Spacer(); Button("Create key",systemImage:"plus") { editor = KeyEditor(record:nil) }
                }
                Text("Read-only keys can read history, download media and manage webhooks. Full access also permits sending and message changes, subject to the account mode.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Keys") {
                if model.keys.isEmpty { ContentUnavailableView("No API keys",systemImage:"key",description:Text("Create a key to connect an integration.")) }
                ForEach(model.keys) { key in
                    HStack {
                        VStack(alignment:.leading,spacing:3) {
                            Text(key.name).fontWeight(.medium)
                            Text("\(key.access.title) · Created \(key.createdAt.formatted(date:.abbreviated,time:.omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editor = KeyEditor(record:key) }
                        Button("Revoke",role:.destructive) { model.revoke(key.id) }
                    }.padding(.vertical,4)
                }
            }
            Text("Changes apply to new calls immediately. Already dispatched operations may finish. Secrets are shown once; only their hashes are saved.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
        .sheet(item:$editor) { item in KeyEditorSheet(model:model,record:item.record) }
    }
}

private struct KeyEditorSheet: View {
    @Bindable var model: AppModel
    let record: APIKeyRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var access: APIKeyAccess
    @State private var secret: String?
    init(model: AppModel, record: APIKeyRecord?) {
        self.model = model; self.record = record
        _name = State(initialValue:record?.name ?? "")
        _access = State(initialValue:record?.access ?? .readOnly)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            if let secret {
                Text("Save your API key").font(.title2.bold())
                Text("This secret is shown once. Save it in your integration's secret settings.").foregroundStyle(.secondary)
                Text(secret).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy key") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(secret,forType:.string) }
                    Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(record == nil ? "Create API key" : "Edit API key").font(.title2.bold())
                TextField("Name",text:$name).disabled(record != nil)
                Picker("Access",selection:$access) { ForEach(APIKeyAccess.allCases) { Text($0.title).tag($0) } }
                Text(access == .readOnly ? "Read messages and media, and manage webhook subscriptions. No sending or message changes." : "Send and manage messages. The account's read-only mode still takes precedence.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(record == nil ? "Create key" : "Save") {
                        if let record { if model.updateKey(record.id,access:access) { dismiss() } }
                        else { secret = model.createKey(name:name,access:access) }
                    }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(24).frame(width:460)
    }
}
