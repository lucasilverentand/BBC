import XCTest
import IMessage
@testable import BBCMessagesActions

@MainActor final class NativeUIResetTests: XCTestCase {
    enum Failure: Error { case action, cleanup }

    func testSubmittedSendIsObservedUntilTheNativeComposerEmpties() throws {
        var reads = 0
        try BBCNativeOwnedComposer.waitForSend(expected: "pending", owns: { true }, read: { reads += 1; return reads < 3 ? "pending" : "" })
        XCTAssertEqual(reads, 3)
    }

    func testOperatorEditDuringSendSettlementStopsCleanup() {
        XCTAssertThrowsError(try BBCNativeOwnedComposer.waitForSend(expected: "pending", owns: { true }, read: { "operator edit" })) {
            XCTAssertEqual($0 as? BBCNativeResetFailure, .draft)
        }
    }

    func testOwnedComposerCleanupPreservesOperatorEditsAndChangedSelections() {
        for (value, owns) in [("personal text", true), (" ", false)] {
            var cleared = false
            XCTAssertThrowsError(try BBCNativeOwnedComposer.clear(expected: " ", owns: { owns }, read: { value }, clear: { cleared = true }))
            XCTAssertFalse(cleared)
        }
    }

    func testOwnedPlaceholderIsClearedAndObservedEmpty() throws {
        var value = " ", clears = 0
        try BBCNativeOwnedComposer.clear(expected: " ", owns: { true }, read: { value }, clear: { clears += 1; value = "" })
        XCTAssertEqual(clears, 1); XCTAssertEqual(value, "")
    }

    func testComposerOwnershipIsRecheckedBeforeWriting() {
        var reads = 0, cleared = false
        XCTAssertThrowsError(try BBCNativeOwnedComposer.clear(expected: " ", owns: { reads += 1; return reads == 1 }, read: { " " }, clear: { cleared = true }))
        XCTAssertFalse(cleared)
    }

    func testDirtyPreflightCannotDispatchOrDiscardADraft() {
        var dispatched = false
        XCTAssertThrowsError(try BBCNativeUICycle.perform(reset: { throw BBCNativeResetFailure.draft }, action: { dispatched = true }))
        XCTAssertFalse(dispatched)
    }

    func testCleanupCompletesBeforeSuccessfulActionReturns() throws {
        var events = [String]()
        let result = try BBCNativeUICycle.perform(reset: { events.append("reset") }, action: { events.append("action"); return 42 })
        events.append("return")
        XCTAssertEqual(result, 42)
        XCTAssertEqual(events, ["reset", "action", "reset", "return"])
    }

    func testFailedActionIsCleanedWithoutRepeatingIt() {
        var resets = 0, actions = 0
        XCTAssertThrowsError(try BBCNativeUICycle.perform(reset: { resets += 1 }, action: {
            actions += 1; throw Failure.action
        })) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(resets, 2); XCTAssertEqual(actions, 1)
    }

    func testCleanupFailureRetainsTheOriginalUncertainAction() {
        var resets = 0
        XCTAssertThrowsError(try BBCNativeUICycle.perform(reset: {
            resets += 1; if resets == 2 { throw BBCNativeResetFailure.draft }
        }, action: { throw Failure.action })) {
            let failure = $0 as? BBCNativeUICleanupFailure
            XCTAssertTrue(failure?.original is Failure)
            XCTAssertEqual(failure?.reset as? BBCNativeResetFailure, .draft)
        }
    }

    func testSuccessfulActionWithBlockedCleanupIsNotReportedAsClean() {
        var resets = 0
        XCTAssertThrowsError(try BBCNativeUICycle.perform(reset: {
            resets += 1; if resets == 2 { throw BBCNativeResetFailure.verification }
        }, action: { 42 })) {
            let failure = $0 as? BBCNativeUICleanupFailure
            XCTAssertNil(failure?.original)
            XCTAssertEqual(failure?.reset as? BBCNativeResetFailure, .verification)
        }
    }

    func testCancellationIsNotRetriedWhenNativeVisibilityDoesNotChange() {
        var cancels = 0
        XCTAssertThrowsError(try BBCNativeUICycle.dismiss(visible: { true }, cancel: { cancels += 1 }))
        XCTAssertEqual(cancels, 1)
    }

    func testDismissalWaitsForObservedAbsence() throws {
        var visibleReads = 0, cancels = 0
        try BBCNativeUICycle.dismiss(visible: { visibleReads += 1; return visibleReads < 4 }, cancel: { cancels += 1 })
        XCTAssertEqual(cancels, 1); XCTAssertEqual(visibleReads, 4)
    }

    func testTypingStartFailureStillCleansItsPartiallyWrittenPlaceholder() async {
        var events = [String]()
        do {
            try await NativeTypingLifecycle.perform(start: { events.append("start"); throw Failure.action },
                wait: { events.append("wait") }, stop: { events.append("stop") })
            XCTFail("Start must fail")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(events, ["start", "stop"])
    }

    func testTypingCleanupFailureCannotReturnSuccess() async {
        do {
            try await NativeTypingLifecycle.perform(start: {}, wait: {}, stop: { throw Failure.cleanup })
            XCTFail("Cleanup must fail")
        } catch { XCTAssertTrue(error is BBCNativeUICleanupFailure) }
    }
}
