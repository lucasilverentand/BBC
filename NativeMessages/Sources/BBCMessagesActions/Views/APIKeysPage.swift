import SwiftUI
import AppKit

private struct KeyEditor: Identifiable {
    let id = UUID()
    let record: APIKeyRecord?
}

struct APIKeysPage: View {
    @Bindable var model: AppModel
    @State private var editor: KeyEditor?
    @State private var selection: UUID?

    var body: some View {
        Group {
            if model.keys.isEmpty {
                ContentUnavailableView {
                    Label("No API keys", systemImage: "key")
                } description: {
                    Text("Create a key for each integration.")
                } actions: {
                    Button("Create key") { editor = KeyEditor(record: nil) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Table(model.keys, selection: $selection) {
                    TableColumn("Name") { key in
                        Text(key.name).fontWeight(.medium).lineLimit(1)
                    }.width(min: 120, ideal: 180)
                    TableColumn("Access") { key in
                        Text(key.access.title)
                    }.width(100)
                    TableColumn("Network") { key in
                        Text(key.allowNetwork ? (key.allowedClients.isEmpty ? "Any client" : "Restricted") : "Local only")
                    }.width(100)
                    TableColumn("Created") { key in
                        Text(key.createdAt, format: .dateTime.day().month().year())
                            .foregroundStyle(.secondary)
                    }.width(min: 100, ideal: 115)
                }
                .onChange(of: selection) { _, id in
                    if let key = model.keys.first(where: { $0.id == id }) {
                        editor = KeyEditor(record: key)
                    }
                }
            }
        }
        .toolbar {
            Button("Create key", systemImage: "plus") { editor = KeyEditor(record: nil) }
                .help("Create API key")
        }
        .sheet(item: $editor, onDismiss: { selection = nil }) { item in
            KeyEditorSheet(model: model, record: item.record)
        }
    }
}

private enum KeyConfirmation { case rotate, revoke }

private struct KeyEditorSheet: View {
    @Bindable var model: AppModel
    let record: APIKeyRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var access: APIKeyAccess
    @State private var allowNetwork: Bool
    @State private var allowedClients: String
    @State private var secret: String?
    @State private var confirmation: KeyConfirmation?
    @State private var submissionError: String?
    private var invalidClients: Bool { (try? IPNetwork.parseList(allowedClients)) == nil }
    private var invalidName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > 100
    }

    private var hasChanges: Bool {
        guard let record else { return false }
        return name != record.name || access != record.access || allowNetwork != record.allowNetwork || allowedClients != record.allowedClients
    }

    init(model: AppModel, record: APIKeyRecord?) {
        self.model = model; self.record = record
        _name = State(initialValue: record?.name ?? "")
        _access = State(initialValue: record?.access ?? .readOnly)
        _allowNetwork = State(initialValue: record?.allowNetwork ?? false)
        _allowedClients = State(initialValue: record?.allowedClients ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(secret != nil ? "Save your API key" : record == nil ? "Create API key" : "Key settings")
                    .font(.title2.bold())
                Spacer()
            }.padding(24)

            if let secret {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Shown once. Copy before closing.").foregroundStyle(.secondary)
                    Text(secret).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }.padding(.horizontal, 24).padding(.bottom, 24)
            } else {
                Form {
                    Section {
                        TextField("Name", text: $name)
                        Picker("Access", selection: $access) {
                            ForEach(APIKeyAccess.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Section {
                        Toggle("Allow network access", isOn: $allowNetwork)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Allowed clients")
                            TextEditor(text: $allowedClients)
                                .font(.system(.body, design: .monospaced)).frame(height: 72)
                                .accessibilityLabel("Allowed client IP addresses and CIDR ranges")
                            Text("Optional. IP or CIDR, one per line.")
                                .font(.caption).foregroundStyle(.secondary)
                            if invalidClients {
                                Text("Enter valid IP addresses or CIDR ranges.").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }.formStyle(.grouped).frame(height: 320)
            }
            if let submissionError {
                Text(submissionError).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            Divider()
            HStack {
                if let secret {
                    Button("Copy key") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(secret, forType: .string)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    if record != nil {
                        Button("Revoke key…", role: .destructive) { confirmation = .revoke }
                        Button("Rotate key…") { confirmation = .rotate }
                            .disabled(hasChanges)
                            .help(hasChanges ? "Save changes before rotating this key" : "Replace this key’s secret")
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(record == nil ? "Create key" : "Save") { save() }
                        .keyboardShortcut(.defaultAction).disabled(invalidName || invalidClients)
                }
            }.padding(16)
        }.frame(width: 520)
        .interactiveDismissDisabled(secret != nil)
        .alert(confirmation == .rotate ? "Rotate this key?" : "Revoke this key?",
               isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
               presenting: confirmation) { action in
            Button("Cancel", role: .cancel) {}
            Button(action == .rotate ? "Rotate key" : "Revoke key", role: .destructive) {
                guard let record else { return }
                submissionError = nil
                if action == .rotate {
                    secret = model.rotateKey(record.id)
                    if secret == nil { submissionError = model.error }
                } else {
                    model.revoke(record.id)
                    if !model.keys.contains(where: { $0.id == record.id }) { dismiss() }
                    else { submissionError = model.error }
                }
            }
        } message: { action in
            Text(action == .rotate
                 ? "The old key stops working immediately. Update your integrations with the new key."
                 : "Integrations using this key will lose access. This cannot be undone.")
        }
    }

    private func save() {
        if let record {
            if model.updateKey(record.id, name: name, access: access, allowedClients: allowedClients, allowNetwork: allowNetwork) { dismiss() }
            else { submissionError = model.error }
        } else {
            secret = model.createKey(name: name, access: access, allowedClients: allowedClients, allowNetwork: allowNetwork)
            if secret == nil { submissionError = model.error }
        }
    }
}
