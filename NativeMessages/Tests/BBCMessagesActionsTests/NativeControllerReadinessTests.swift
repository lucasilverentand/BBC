import Darwin
import Foundation
import XCTest
@preconcurrency @testable import IMessage
@testable import BBCMessagesActions

final class NativeControllerReadinessTests: XCTestCase {
    func testDisabledCoordinationUnhidesOnlyVerifiedBBCProcess() {
        XCTAssertTrue(BBCControllerWindowPolicy.mayUnhide(coordinating: false, effectiveUID: getuid(), processUID: getuid()))
        for coordinate in [false, true] {
            for effective: UInt32 in [0, (getuid() + 1), getuid(), (getuid() + 2)] {
                for process: UInt32? in [nil, 0, (getuid() + 1), getuid(), (getuid() + 2)] {
                    XCTAssertEqual(BBCControllerWindowPolicy.mayUnhide(coordinating: coordinate, effectiveUID: effective, processUID: process), !coordinate && effective != 0 && process == effective)
                }
            }
        }
    }
    func testStageWrapperDropsPrivateUnderlyingErrorsAndPreservesTypedOwnership() throws {
        let privateError = NSError(domain: "private-path-and-body", code: 7, userInfo: nil)
        for stage in BBCNativeControllerFailure.allCases {
            XCTAssertThrowsError(try BBCNativeControllerFailure.at(stage) { throw privateError }) { error in
                XCTAssertEqual(error as? BBCNativeControllerFailure, stage)
                XCTAssertFalse(String(describing: error).contains("private"))
            }
        }
        XCTAssertThrowsError(try BBCNativeControllerFailure.at(.launch) { throw BBCNativeControllerFailure.ownership }) { error in
            XCTAssertEqual(error as? BBCNativeControllerFailure, .ownership)
        }
        var calls = 0
        XCTAssertEqual(try BBCNativeControllerFailure.at(.launch) { calls += 1; return 42 }, 42)
        XCTAssertEqual(calls, 1)
    }
    func testEveryConstructorFailureHasABoundedPreActionReadCode() {
        let expected = ["accessibility", "coordination", "discovery", "ownership", "launch", "window", "responsiveness"]
        XCTAssertEqual(BBCNativeControllerFailure.allCases.map(\.rawValue), expected)
        for error in BBCNativeControllerFailure.allCases {
            let result = NativeReadFailureDisposition.resolve(error, phase: "read_ui", attempted: true)
            XCTAssertEqual(result.phase, "read_controller_" + error.rawValue)
            XCTAssertFalse(result.attempted)
            XCTAssertLessThan(result.phase.utf8.count, 48)
        }
    }
    func testLaterReadFailuresKeepUncertainActionBoundary() {
        for error in [BBCNativeReadFailure.resolution, .preparation, .selection, .focus, .transcript, .cell, .markAction] {
            let result = NativeReadFailureDisposition.resolve(error, phase: "read_ui", attempted: true)
            XCTAssertEqual(result.phase, "read_" + error.rawValue)
            XCTAssertTrue(result.attempted)
        }
        XCTAssertFalse(NativeReadFailureDisposition.resolve(BBCNativeReadFailure.controller, phase: "read_ui", attempted: true).attempted)
    }
    func testConstructorReadClassificationCannotRelabelReplyOrTapback() {
        for phase in ["reply_ui", "reaction_ui", "read_confirmation"] {
            let result = NativeReadFailureDisposition.resolve(BBCNativeControllerFailure.window, phase: phase, attempted: true)
            XCTAssertEqual(result.phase, phase); XCTAssertTrue(result.attempted)
        }
    }
    func testUnknownErrorDoesNotLeakPrivateDescriptionOrClaimNoAction() {
        let secretError = NSError(domain: "private-path-and-message", code: 123, userInfo: [NSLocalizedDescriptionKey: "private-handle-and-body"])
        let result = NativeReadFailureDisposition.resolve(secretError, phase: "read_confirmation", attempted: true)
        XCTAssertEqual(result.phase, "read_confirmation"); XCTAssertTrue(result.attempted)
        XCTAssertFalse(result.phase.contains("private"))
    }
}
