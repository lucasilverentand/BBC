import AppKit
import XCTest
@testable import BBCMessagesActions

@MainActor final class MessageSendScriptTests: XCTestCase {
    private func assertCompiles(_ source: String) throws {
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), "Send script did not compile")
        XCTAssertNil(error)
        // Compilation only. Never execute a send from an automated test.
    }
    func testTextSendCompilesWithMessagesDictionaryAndEscapedLiterals() throws {
        try assertCompiles(MessageSendScript.text(to: "fixture@example.test", text: "A \"quoted\" message\\with\nline breaks\r🎉"))
    }
    func testFileReferenceCompilesWithoutReadingOrSendingTheFile() throws {
        try assertCompiles(MessageSendScript.file(to: "fixture@example.test", file: URL(fileURLWithPath: "/private/tmp/BBC fixture.caf")))
    }
}
