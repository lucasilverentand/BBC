import Darwin
import Foundation
import XCTest
@preconcurrency @testable import IMessage

final class ThreadSelectionBoundaryTests: XCTestCase {
    func testFocusNotificationDuringOpeningIsNotLost() {
        let open = Date(timeIntervalSince1970: 100)
        let duringOpen = open.addingTimeInterval(0.01)
        let returned = open.addingTimeInterval(0.04)
        XCTAssertTrue(BBCThreadSelectionBoundary.observedChange(duringOpen, since: open))
        // Regression oracle: the old after-open boundary rejects this valid event.
        XCTAssertFalse(BBCThreadSelectionBoundary.observedChange(duringOpen, since: returned))
        XCTAssertFalse(BBCThreadSelectionBoundary.observedChange(nil, since: open))
        XCTAssertFalse(BBCThreadSelectionBoundary.observedChange(open.addingTimeInterval(-0.01), since: open))
    }

    func testAlreadySelectedExactDirectChatNeedsNoNewFocusEvent() {
        XCTAssertFalse(BBCThreadSelectionBoundary.observedChange(nil, since: Date()))
        XCTAssertTrue(BBCThreadSelectionBoundary.mayReuseSelectedDirectChat(
            address: "owner@example.invalid", isGroup: false,
            beforeTitle: "owner@example.invalid", afterTitle: "owner@example.invalid", sameSelectedRow: true))
    }

    func testWrongOrAmbiguousChatCannotUseAlreadySelectedBypass() {
        let address = "owner@example.invalid"
        for (before, after, row) in [(address,"other@example.invalid",true),
                                     ("other@example.invalid",address,true),
                                     (address,address,false),
                                     ("Owner","Owner",true)] {
            XCTAssertFalse(BBCThreadSelectionBoundary.mayReuseSelectedDirectChat(
                address: address, isGroup: false, beforeTitle: before, afterTitle: after, sameSelectedRow: row))
        }
        for group in [false,true] {
            XCTAssertFalse(BBCThreadSelectionBoundary.mayReuseSelectedDirectChat(
                address: address, isGroup: group, beforeTitle: nil, afterTitle: address, sameSelectedRow: true))
        }
        XCTAssertFalse(BBCThreadSelectionBoundary.mayReuseSelectedDirectChat(
            address: address, isGroup: true, beforeTitle: address, afterTitle: address, sameSelectedRow: true))
        XCTAssertFalse(BBCThreadSelectionBoundary.mayReuseSelectedDirectChat(
            address: "urn:biz:synthetic", isGroup: false, beforeTitle: "urn:biz:synthetic", afterTitle: "urn:biz:synthetic", sameSelectedRow: true))
        // Neither a stale focus event nor a wrong chat grants admission.
        XCTAssertFalse(BBCThreadSelectionBoundary.observedChange(Date(timeIntervalSince1970: 99), since: Date(timeIntervalSince1970: 100)))
    }
}
