import Darwin
import XCTest
@preconcurrency @testable import IMessage

final class ReplyDraftPolicyTests: XCTestCase {
    func testUnselectedFreshWindowCanSelectItsExactTargetWithoutAnEditor() {
        XCTAssertTrue(BBCReplyDraftPolicy.maySelectTarget(draft: nil, selectedCount: 0))
        XCTAssertFalse(BBCReplyDraftPolicy.maySelectTarget(draft: nil, selectedCount: nil))
        XCTAssertFalse(BBCReplyDraftPolicy.maySelectTarget(draft: nil, selectedCount: 1))
    }
    func testEveryActualDraftIncludingWhitespaceIsPreserved() {
        for text in ["unsent", " ", "\n"] {
            for count: Int? in [nil, 0, 1] {
                XCTAssertFalse(BBCReplyDraftPolicy.maySelectTarget(draft: text, selectedCount: count))
            }
        }
        XCTAssertTrue(BBCReplyDraftPolicy.maySelectTarget(draft: "", selectedCount: 1))
    }
    func testUnavailableEditorHasADistinctPreSendFailure() {
        XCTAssertNotEqual(BBCNativeReplyFailure.editorUnavailable, .existingDraft)
        XCTAssertNotEqual(BBCNativeReplyFailure.editorUnavailable, .send)
    }
}
