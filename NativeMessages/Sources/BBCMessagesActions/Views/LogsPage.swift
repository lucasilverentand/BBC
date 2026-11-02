import SwiftUI
import AppKit

struct LogsPage: View {
    let log: AppLog
    var body: some View {
        VStack(spacing: 0) {
            if log.storageError {
                Label("Log history couldn’t be saved or loaded.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
            if log.entries.isEmpty {
                ContentUnavailableView("No activity", systemImage: "list.bullet.rectangle")
            } else {
                List(log.entries.reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                            .help(entry.date.formatted(date: .abbreviated, time: .standard))
                        Text(entry.level.rawValue).font(.caption)
                            .foregroundStyle(entry.level == .error ? Color.red : Color.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(entry.message).frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }.padding(.vertical, 3)
                }.listStyle(.inset)
            }
        }
        .toolbar {
            Button("Copy logs", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.text, forType: .string)
            }.disabled(log.entries.isEmpty)
            Button("Clear logs", systemImage: "trash") { log.clear() }
                .disabled(log.entries.isEmpty)
        }
    }
}
