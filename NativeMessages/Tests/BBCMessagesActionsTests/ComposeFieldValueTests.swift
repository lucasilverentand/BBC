import Darwin
import Foundation
import XCTest
@preconcurrency @testable import IMessage

final class ComposeFieldValueTests: XCTestCase {
    func testPlainAndAttributedValuesKeepExactDraftIncludingWhitespace() {
        for text in ["", " ", "\n", "unsent 👩🏽‍💻", "reply\nsecond line"] {
            XCTAssertEqual(BBCComposeFieldValue.text(from: text), text)
            XCTAssertEqual(BBCComposeFieldValue.text(from: NSAttributedString(string: text)), text)
        }
    }
    func testUnsupportedAndMissingValuesRemainUnavailable() {
        for value: Any? in [nil, NSNull(), 42, Data()] {
            XCTAssertNil(BBCComposeFieldValue.text(from: value))
        }
    }
    func testPlainWhitespaceRemainsAnExistingDraftForReply() {
        let draft = BBCComposeFieldValue.text(from: " ")
        XCTAssertFalse(BBCReplyDraftPolicy.maySelectTarget(draft: draft, selectedCount: 1))
        XCTAssertTrue(BBCReplyDraftPolicy.maySelectTarget(draft: BBCComposeFieldValue.text(from: ""), selectedCount: 1))
    }
}
