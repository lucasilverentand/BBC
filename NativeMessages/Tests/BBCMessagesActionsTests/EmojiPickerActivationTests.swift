import XCTest
import IMessage

final class EmojiPickerActivationTests: XCTestCase {
    func testChangedSearchStopsBeforeAnyActivation() {
        var reads = 0, activations = 0
        XCTAssertThrowsError(try {
            try BBCNativeEmojiActivation.waitForSearch(owned: { reads += 1; return reads < 3 })
            _ = try BBCNativeEmojiActivation.perform(supported: ["AXPress"], activate: { _ in activations += 1 }, selected: { nil }, confirmSelection: nil)
        }())
        XCTAssertEqual(activations, 0)
    }

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
}
