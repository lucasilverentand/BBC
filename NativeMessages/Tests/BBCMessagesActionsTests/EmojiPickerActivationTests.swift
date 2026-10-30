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

    func testUnknownGlyphUsesOneProcessClickWithoutAnAXPress() throws {
        var calls = [String]()
        let action = try BBCNativeEmojiActivation.perform(supported: ["AXPress"], activate: { calls.append($0) }, selected: { nil }, confirmSelection: nil, role: "AXUnknown", processClick: { calls.append("click") })
        XCTAssertEqual(action, "process-click")
        XCTAssertEqual(calls, ["click"])
    }

    func testFailedProcessClickNeverFallsBackToPress() {
        var calls = [String]()
        XCTAssertThrowsError(try BBCNativeEmojiActivation.perform(supported: ["AXPress"], activate: { calls.append($0) }, selected: { nil }, confirmSelection: nil, role: "AXUnknown", processClick: {
            calls.append("click")
            throw BBCNativeReactionFailure.choice
        }))
        XCTAssertEqual(calls, ["click"])
    }

    func testSemanticButtonsKeepTheirAdvertisedAction() throws {
        var calls = [String]()
        _ = try BBCNativeEmojiActivation.perform(supported: ["AXPress"], activate: { calls.append($0) }, selected: { nil }, confirmSelection: nil, role: "AXButton", processClick: { calls.append("click") })
        XCTAssertEqual(calls, ["AXPress"])
    }

    func testClickGeometryAllowsNegativeScreenOrigins() throws {
        XCTAssertEqual(try BBCNativeEmojiClickGeometry.point(glyph: CGRect(x: -400, y: 100, width: 30, height: 30), picker: CGRect(x: -500, y: 0, width: 346, height: 470)), CGPoint(x: -385, y: 115))
    }

    func testClickGeometryRejectsClippedOrInvalidTargets() {
        let picker = CGRect(x: 0, y: 0, width: 346, height: 470)
        for glyph in [CGRect(x: -1, y: 20, width: 30, height: 30), CGRect.zero, CGRect(x: 1, y: 1, width: 200, height: 30), CGRect(x: Double.infinity, y: 20, width: 30, height: 30)] {
            XCTAssertThrowsError(try BBCNativeEmojiClickGeometry.point(glyph: glyph, picker: picker))
        }
    }
}
