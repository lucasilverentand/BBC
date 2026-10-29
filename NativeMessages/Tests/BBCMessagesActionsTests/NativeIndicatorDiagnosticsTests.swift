import XCTest
import Darwin
@preconcurrency import IMessage
@testable import BBCMessagesActions

final class NativeIndicatorDiagnosticsTests: XCTestCase {
    func testControllerSetupFailureIsDistinctFromUncertainCleanup() {
        let setup = NativeIndicatorFailure.resolve(BBCNativeControllerFailure.window, phase: "typing_start", attempted: true)
        XCTAssertEqual(setup.phase, "typing_controller_window"); XCTAssertFalse(setup.attempted)
        let cleanup = NativeIndicatorFailure.resolve(BBCNativeControllerFailure.window, phase: "typing_cleanup", attempted: true)
        XCTAssertEqual(cleanup.phase, "typing_cleanup"); XCTAssertTrue(cleanup.attempted)
        let action = NativeIndicatorFailure.resolve(ActionFailure.uncertain, phase: "typing_start", attempted: true)
        XCTAssertEqual(action.phase, "typing_start"); XCTAssertTrue(action.attempted)
    }
    func testOnlyFixedTypingFailureStagesCanEnterLogs() {
        for stage in NativeIndicatorFailure.phases.union(NativeIndicatorFailure.controllerPhases) {
            XCTAssertEqual(NativeIndicatorFailure.label(stage), stage)
        }
        for unsafe in ["owner@example.test", "/private/message/path", "typing_start secret", "typing_controller_owner@example.test"] {
            XCTAssertEqual(NativeIndicatorFailure.label(unsafe), "typing_unknown")
        }
    }
    func testTypingBodyStagesPreserveUncertaintyAndEmptyWindowDraftFences() {
        for stage in BBCNativeTypingFailure.allCases {
            let failure = NativeIndicatorFailure.resolve(stage, phase: "typing_start", attempted: true)
            XCTAssertEqual(failure.phase, "typing_start_" + stage.rawValue)
            XCTAssertTrue(failure.attempted)
            XCTAssertEqual(NativeIndicatorFailure.label(failure.phase), failure.phase)
        }
        XCTAssertTrue(BBCReplyDraftPolicy.maySelectTarget(draft: nil, selectedCount: 0))
        for count: Int? in [nil, 1, 2] { XCTAssertFalse(BBCReplyDraftPolicy.maySelectTarget(draft: nil, selectedCount: count)) }
        XCTAssertFalse(BBCReplyDraftPolicy.maySelectTarget(draft: " ", selectedCount: 0))
        XCTAssertFalse(BBCReplyDraftPolicy.maySelectTarget(draft: "keep this draft", selectedCount: 0))
    }
    func testObservationSchemaCannotCarryUIContents() throws {
        let data = try JSONEncoder().encode(NativeMessagesObservation.Snapshot())
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(Set(fields.keys).isSubset(of: ["processFound", "hidden", "active", "windowsStatus", "windowCount", "mainWindowStatus", "focusedWindowStatus", "menuBarStatus", "storedWindowCoordination", "sectionWindows", "sectionEntries", "sectionFailure", "conversationLists", "selectedConversations", "composeFields", "textAreas", "tables", "outlines", "scrollAreas", "sheets", "groups", "buttons", "staticTexts", "images", "visited", "scanComplete"]))
        XCTAssertTrue(fields.values.allSatisfy { $0 is NSNumber })
    }
}
