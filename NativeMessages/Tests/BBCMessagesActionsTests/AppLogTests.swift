import Foundation
import XCTest
@testable import BBCMessagesActions

@MainActor final class AppLogTests: XCTestCase {
    func testBoundedHistoryPersistsAndClears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AppLog(directory: directory)
        for index in 0...AppLog.capacity { log.record("Event \(index)", level: index == AppLog.capacity ? .error : .info) }
        XCTAssertEqual(log.entries.count, AppLog.capacity)
        XCTAssertEqual(log.entries.first?.message, "Event 1")
        let restored = AppLog(directory: directory)
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
