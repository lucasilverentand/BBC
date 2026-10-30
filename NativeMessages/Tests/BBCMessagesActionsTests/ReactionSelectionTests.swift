import XCTest
import IMessage

final class ReactionSelectionTests: XCTestCase {
    func testSelectedReactionIsPressedOnceWhileDelayedStateIsObserved() throws {
        var reads = 0, presses = 0
        try BBCNativeReactionSelection.perform(desired: false, selected: {
            reads += 1
            return reads < 4
        }, press: { presses += 1 })
        XCTAssertEqual(presses, 1)
        XCTAssertGreaterThanOrEqual(reads, 4)
    }

    func testAbsentReactionNeverGetsAdded() throws {
        var presses = 0
        try BBCNativeReactionSelection.perform(desired: false, selected: { false }, press: { presses += 1 })
        XCTAssertEqual(presses, 0)
    }

    func testUnknownStateNeverToggles() {
        var presses = 0
        XCTAssertThrowsError(try BBCNativeReactionSelection.perform(desired: false, selected: { throw BBCNativeReactionFailure.picker }, press: { presses += 1 }))
        XCTAssertEqual(presses, 0)
    }

    func testMissingConfirmationNeverRepeatsThePress() {
        var presses = 0
        XCTAssertThrowsError(try BBCNativeReactionSelection.perform(desired: false, selected: { true }, press: { presses += 1 }))
        XCTAssertEqual(presses, 1)
    }

    func testUnselectedCustomReactionIsAddedOnceAndConfirmed() throws {
        var reads = 0, presses = 0
        try BBCNativeReactionSelection.perform(desired: true, selected: {
            reads += 1
            return reads >= 4
        }, press: { presses += 1 })
        XCTAssertEqual(presses, 1)
        XCTAssertGreaterThanOrEqual(reads, 4)
    }

    func testAlreadySelectedReactionNeverGetsToggledOff() throws {
        var presses = 0
        try BBCNativeReactionSelection.perform(desired: true, selected: { true }, press: { presses += 1 })
        XCTAssertEqual(presses, 0)
    }

    func testUnconfirmedAdditionNeverRepeatsThePress() {
        var presses = 0
        XCTAssertThrowsError(try BBCNativeReactionSelection.perform(desired: true, selected: { false }, press: { presses += 1 }))
        XCTAssertEqual(presses, 1)
    }

}
