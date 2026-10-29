import Darwin
import Foundation
import XCTest
@testable import BBCMessagesActions

final class AttachmentFileTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("Library/Messages/Attachments")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aa/bb"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home, root)
    }
    func testOnlyBoundedRegularFileUnderMessagesAttachmentsIsRead() throws {
        try fixture { home, root in
            let file = root.appendingPathComponent("aa/bb/voice.caf"), bytes = Data("synthetic audio fixture".utf8)
            try bytes.write(to: file)
            XCTAssertEqual(try AttachmentFile.read(file.path, home: home), bytes)
            XCTAssertEqual(try AttachmentFile.read("~/Library/Messages/Attachments/aa/bb/voice.caf", home: home), bytes)
            XCTAssertThrowsError(try AttachmentFile.read(file.path, home: home, maximumBytes: 4))
            XCTAssertThrowsError(try AttachmentFile.read(root.appendingPathComponent("aa/bb").path, home: home))
        }
    }
    func testTraversalOtherUsersURLsAndEmptyComponentsAreRejected() throws {
        try fixture { home, root in
            for path in ["/Users/other/Library/Messages/Attachments/audio.caf", "https://example.test/audio.caf",
                         "file://" + root.path + "/audio.caf", root.path + "/aa/../audio.caf",
                         root.path + "//audio.caf", root.path + "/aa/./audio.caf", root.path + "/audio\0.caf"] {
                XCTAssertThrowsError(try AttachmentFile.read(path, home: home))
            }
        }
    }
    func testSymlinkFilesAndIntermediateDirectoriesCannotEscape() throws {
        try fixture { home, root in
            let outside = home.appendingPathComponent("private.caf")
            try Data("unrelated data".utf8).write(to: outside)
            let fileLink = root.appendingPathComponent("aa/file.caf")
            try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: outside)
            XCTAssertThrowsError(try AttachmentFile.read(fileLink.path, home: home))
            let directoryLink = root.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: home)
            XCTAssertThrowsError(try AttachmentFile.read(directoryLink.appendingPathComponent("private.caf").path, home: home))
        }
    }
    func testSymlinkAtAttachmentRootAndNonRegularFilesAreRejected() throws {
        try fixture { home, root in
            let empty = root.appendingPathComponent("empty.caf")
            try Data().write(to: empty)
            XCTAssertThrowsError(try AttachmentFile.read(empty.path, home: home))
            try FileManager.default.moveItem(at: root, to: home.appendingPathComponent("moved"))
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: home.appendingPathComponent("moved"))
            XCTAssertThrowsError(try AttachmentFile.read(empty.path, home: home))
        }
    }
}
