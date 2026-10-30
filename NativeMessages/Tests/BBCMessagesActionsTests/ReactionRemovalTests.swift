import XCTest
import IMessage

final class ReactionRemovalTests: XCTestCase {
    func testSelectedReactionIsPressedOnceWhileDelayedStateIsObserved() throws {
        var reads = 0, presses = 0
        try BBCReactionRemoval.perform(selected: {
            reads += 1
            return reads < 4
        }, press: { presses += 1 })
        XCTAssertEqual(presses, 1)
        XCTAssertGreaterThanOrEqual(reads, 4)
    }

    func testAbsentReactionNeverGetsAdded() throws {
        var presses = 0
        try BBCReactionRemoval.perform(selected: { false }, press: { presses += 1 })
        XCTAssertEqual(presses, 0)
    }

    func testUnknownStateNeverToggles() {
        var presses = 0
        XCTAssertThrowsError(try BBCReactionRemoval.perform(selected: { throw BBCNativeReactionFailure.picker }, press: { presses += 1 }))
        XCTAssertEqual(presses, 0)
    }

    func testMissingConfirmationNeverRepeatsThePress() {
        var presses = 0
        XCTAssertThrowsError(try BBCReactionRemoval.perform(selected: { true }, press: { presses += 1 }))
        XCTAssertEqual(presses, 1)
    }
}
