import Foundation
import XCTest
@testable import BBCMessagesActions

@MainActor final class AppLogTests: XCTestCase {
    func testBoundedHistoryPersistsAndClears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Synthetic files must remain readable when the host keybag is unavailable.
        // Production keeps its completeFileProtectionUnlessOpen default.
        let log = AppLog(directory: directory, writingOptions: .atomic)
        for index in 0...AppLog.capacity { log.record("Event \(index)", level: index == AppLog.capacity ? .error : .info) }
        XCTAssertEqual(log.entries.count, AppLog.capacity)
        XCTAssertEqual(log.entries.first?.message, "Event 1")
        let saved = try JSONDecoder().decode([AppLogEntry].self, from: Data(contentsOf: directory.appendingPathComponent("activity-log.json")))
        XCTAssertEqual(saved.count, AppLog.capacity)
        let restored = AppLog(directory: directory, writingOptions: .atomic)
        XCTAssertEqual(restored.entries.count, AppLog.capacity)
        XCTAssertEqual(restored.entries.last?.level, .error)
        XCTAssertTrue(restored.text.contains("[Error] Event \(AppLog.capacity)"))
        XCTAssertFalse(restored.storageError)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("activity-log.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        restored.clear()
        XCTAssertTrue(AppLog(directory: directory).entries.isEmpty)
    }
    func testUnavailableStorageKeepsSessionHistory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let log = AppLog(directory: file)
        log.record("API stopped.")
        XCTAssertTrue(log.storageError)
        XCTAssertEqual(log.entries.last?.message, "API stopped.")
    }
}
