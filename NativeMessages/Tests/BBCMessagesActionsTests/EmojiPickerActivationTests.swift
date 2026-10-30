import XCTest
import IMessage

final class EmojiPickerActivationTests: XCTestCase {
    func testAdvertisedConfirmActivatesOnceWithoutPress() throws {
        var calls = [String]()
        let action = try BBCNativeEmojiActivation.perform(supported: ["AXPress", "AXConfirm"], activate: { calls.append($0) }, selected: { true }, confirmSelection: { calls.append("parent") })
        XCTAssertEqual(action, "AXConfirm")
        XCTAssertEqual(calls, ["AXConfirm"])
    }

    func testAdvertisedPickActivatesOnceWithoutPress() throws {
        var calls = [String]()
        _ = try BBCNativeEmojiActivation.perform(supported: ["AXPress", "AXPick"], activate: { calls.append($0) }, selected: { false }, confirmSelection: nil)
        XCTAssertEqual(calls, ["AXPick"])
    }

    func testPressSelectsBeforeOwnedContainerConfirmation() throws {
        var calls = [String](), reads = 0
        let action = try BBCNativeEmojiActivation.perform(supported: ["AXPress"], activate: { calls.append($0) }, selected: {
            reads += 1
            return reads >= 3
        }, confirmSelection: { calls.append("parent-confirm") })
        XCTAssertEqual(action, "AXPress+AXConfirm")
        XCTAssertEqual(calls, ["AXPress", "parent-confirm"])
    }

    func testUnknownSelectionDoesNotConfirmAnotherContainer() throws {
        var calls = [String]()
        _ = try BBCNativeEmojiActivation.perform(supported: ["AXPress"], activate: { calls.append($0) }, selected: { nil }, confirmSelection: { calls.append("parent") })
        XCTAssertEqual(calls, ["AXPress"])
    }

    func testFailedActivationNeverFallsBackToAnotherAction() {
        var calls = [String]()
        XCTAssertThrowsError(try BBCNativeEmojiActivation.perform(supported: ["AXConfirm", "AXPick", "AXPress"], activate: {
            calls.append($0)
            throw BBCNativeReactionFailure.apply
        }, selected: { true }, confirmSelection: nil))
        XCTAssertEqual(calls, ["AXConfirm"])
    }

    func testUnsupportedActionsAreNeverInvoked() {
        var calls = [String]()
        XCTAssertThrowsError(try BBCNativeEmojiActivation.perform(supported: ["AXShowMenu"], activate: { calls.append($0) }, selected: { true }, confirmSelection: nil))
        XCTAssertTrue(calls.isEmpty)
    }

    func testRowSelectionIsObservedBeforeOneConfirmation() throws {
        var calls = [String](), reads = 0
        try BBCNativeEmojiPickerSelection.confirm(select: { calls.append("select") }, selected: {
            reads += 1
            return reads >= 3
        }, owned: { true }, submit: { calls.append("confirm") })
        XCTAssertEqual(calls, ["select", "confirm"])
    }

    func testUnknownRowSelectionNeverConfirms() {
        var calls = [String]()
        XCTAssertThrowsError(try BBCNativeEmojiPickerSelection.confirm(select: { calls.append("select") }, selected: { nil }, owned: { true }, submit: { calls.append("confirm") }))
        XCTAssertEqual(calls, ["select"])
    }

    func testChangedSearchPreventsSelection() {
        var calls = [String]()
        XCTAssertThrowsError(try BBCNativeEmojiPickerSelection.confirm(select: { calls.append("select") }, selected: { true }, owned: { false }, submit: { calls.append("confirm") }))
        XCTAssertTrue(calls.isEmpty)
    }

    func testLostOwnershipAfterSelectionPreventsConfirmation() {
        var calls = [String](), owned = true
        XCTAssertThrowsError(try BBCNativeEmojiPickerSelection.confirm(select: { calls.append("select"); owned = false }, selected: { true }, owned: { owned }, submit: { calls.append("confirm") }))
        XCTAssertEqual(calls, ["select"])
    }

    func testFailedConfirmationIsNotRetried() {
        var confirmations = 0
        XCTAssertThrowsError(try BBCNativeEmojiPickerSelection.confirm(select: {}, selected: { true }, owned: { true }, submit: {
            confirmations += 1
            throw BBCNativeEmojiPickerSelection.Failure.confirmation
        }))
        XCTAssertEqual(confirmations, 1)
    }

    func testMissingSelectionConfirmationDoesNotReselectOrSubmit() {
        var calls = [String]()
        XCTAssertThrowsError(try BBCNativeEmojiPickerSelection.confirm(select: { calls.append("select") }, selected: { false }, owned: { true }, submit: { calls.append("confirm") }))
        XCTAssertEqual(calls, ["select"])
    }
}
