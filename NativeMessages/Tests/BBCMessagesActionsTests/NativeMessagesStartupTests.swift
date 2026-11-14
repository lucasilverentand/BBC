import Darwin
import XCTest
@testable import BBCMessagesActions

@MainActor final class NativeMessagesStartupTests: XCTestCase {
    func testMissingProcessLaunchesOnceAndUsesItsExactPID() async throws {
        var launches = 0
        let pid = try await NativeMessagesStartup.ensureRunning(effectiveUID: getuid(), lookup: { nil }) {
            launches += 1
            return .init(pid: 42, uid: getuid())
        }
        XCTAssertEqual(pid, 42); XCTAssertEqual(launches, 1)
    }
    func testExistingBBCProcessNeverLaunchesAgain() async throws {
        let pid = try await NativeMessagesStartup.ensureRunning(effectiveUID: getuid(), lookup: { .init(pid: 43, uid: getuid()) }) {
            XCTFail("Existing process must be reused")
            throw ActionFailure.invalid
        }
        XCTAssertEqual(pid, 43)
    }
    func testOtherRuntimeUserCannotDiscoverOrLaunch() async {
        for uid: UInt32 in [0, (getuid() + 1), (getuid() + 2)] {
            do {
                _ = try await NativeMessagesStartup.ensureRunning(effectiveUID: uid, lookup: { XCTFail("Wrong user must not discover"); return nil }) {
                    XCTFail("Wrong user must not launch"); throw ActionFailure.invalid
                }
                XCTFail("Expected rejection")
            } catch {}
        }
    }
    func testWrongOwnerOrInvalidPIDIsRejectedForExistingAndNewProcesses() async {
        for candidate in [NativeMessagesStartup.Process(pid: 44, uid: (getuid() + 1)), .init(pid: 0, uid: getuid())] {
            for existing in [true, false] {
                do {
                    _ = try await NativeMessagesStartup.ensureRunning(effectiveUID: getuid(), lookup: { existing ? candidate : nil }) { candidate }
                    XCTFail("Expected ownership/PID rejection")
                } catch {}
            }
        }
    }
    func testLaunchPlanLetsTheBridgeOwnTheMessagesLaunch() {
        XCTAssertEqual(NativeMessagesStartup.launchPlan(openHidden: true, connectBridge: true, fullAccess: true), .connectBridge)
        XCTAssertEqual(NativeMessagesStartup.launchPlan(openHidden: false, connectBridge: true, fullAccess: true), .connectBridge)
    }
    func testLaunchPlanOpensHiddenWithoutABridgeSession() {
        XCTAssertEqual(NativeMessagesStartup.launchPlan(openHidden: true, connectBridge: false, fullAccess: true), .openHidden)
        XCTAssertEqual(NativeMessagesStartup.launchPlan(openHidden: true, connectBridge: true, fullAccess: false), .openHidden)
    }
    func testLaunchPlanDoesNothingWhenDisabled() {
        XCTAssertEqual(NativeMessagesStartup.launchPlan(openHidden: false, connectBridge: false, fullAccess: true), .none)
        XCTAssertEqual(NativeMessagesStartup.launchPlan(openHidden: false, connectBridge: true, fullAccess: false), .none)
    }
}
