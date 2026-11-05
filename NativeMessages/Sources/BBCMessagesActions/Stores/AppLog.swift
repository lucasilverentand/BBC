import Foundation
import Observation

struct AppLogEntry: Codable, Identifiable {
    enum Level: String, Codable { case info = "Info", error = "Error" }
    let id: UUID
    let date: Date
    let level: Level
    let message: String
}

/// Bounded local operational history. Callers supply fixed messages, never payloads or secrets.
@MainActor @Observable final class AppLog {
    static let capacity = 500
    private(set) var entries: [AppLogEntry] = []
    private(set) var storageError = false
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let writingOptions: Data.WritingOptions

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blue Bubble Club"),
         writingOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]) {
        file = directory.appendingPathComponent("activity-log.json")
        self.writingOptions = writingOptions
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: file.path) {
                entries = Array(try JSONDecoder().decode([AppLogEntry].self, from: Data(contentsOf: file)).suffix(Self.capacity))
            }
        } catch { storageError = true }
    }

    func record(_ message: String, level: AppLogEntry.Level = .info) {
        entries.append(.init(id: UUID(), date: Date(), level: level, message: message))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        save()
    }

    func clear() { entries.removeAll(); save() }

    var text: String {
        entries.map { "\($0.date.formatted(.iso8601)) [\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
    }

    private func save() {
        do {
            try JSONEncoder().encode(entries).write(to: file, options: writingOptions)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageError = false
        } catch { storageError = true }
    }
}
