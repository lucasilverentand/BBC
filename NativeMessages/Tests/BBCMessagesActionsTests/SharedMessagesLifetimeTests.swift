import Foundation
import XCTest
import Darwin
@preconcurrency @testable import IMessage

final class SharedMessagesLifetimeTests: XCTestCase {
    func testStoredDesktopOverridesCannotCreateAnEclipsingOrSpacesCoordinator() throws {
        guard ProcessInfo.processInfo.environment["BBC_TEST_ISOLATED_PREFERENCES"] == "1" else { throw XCTSkip("Set BBC_TEST_ISOLATED_PREFERENCES=1 only in a disposable test account") }
        let defaults = Defaults.imessage, windowKey = DefaultsKeys.windowCoordination, coordinatorKey = DefaultsKeys.coordinator
        let window = defaults.object(forKey: windowKey), coordinator = defaults.object(forKey: coordinatorKey)
        defer {
            if let window { defaults.set(window, forKey: windowKey) } else { defaults.removeObject(forKey: windowKey) }
            if let coordinator { defaults.set(coordinator, forKey: coordinatorKey) } else { defaults.removeObject(forKey: coordinatorKey) }
        }
        defaults.set(true, forKey: windowKey)
        for value in ["spaces", "eclipsing"] {
            defaults.set(value, forKey: coordinatorKey)
            XCTAssertFalse(Defaults.shouldCoordinateWindow)
            let selected = try getBestWindowCoordinator()
            XCTAssertTrue(selected is BBCPassiveWindowCoordinator)
            XCTAssertTrue(selected.canReuseExtantInstance)
            XCTAssertNil(selected.app)
        }
    }
}
