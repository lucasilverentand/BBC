import Darwin
import Foundation
import XCTest
@testable import BBCMessagesActions

final class SelfContainedMovieTests: XCTestCase {
    private func integer(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    private func box(_ type: String, _ body: Data = Data()) -> Data {
        integer(UInt32(body.count+8)) + Data(type.utf8) + body
    }
    private func movie(reference: Data) -> Data {
        let dref = box("dref", integer(0) + integer(1) + reference)
        let track = box("trak", box("mdia", box("minf", box("dinf", dref))))
        return box("ftyp", Data("qt  ".utf8) + integer(0)) + box("moov", track) + box("mdat", Data([0]))
    }
    func testOnlyContainedDataReferencesAreAccepted() throws {
        XCTAssertNoThrow(try SelfContainedMovie.validate(movie(reference: box("url ", integer(1)))))
        XCTAssertNoThrow(try SelfContainedMovie.validate(movie(reference: box("alis", integer(1)))))
        for reference in [box("url ", integer(0) + Data("https://example.test/media\0".utf8)),
                          box("url ", integer(0) + Data("file:///private/unrelated.mov\0".utf8)),
                          box("alis", Data([0,0,0,0])), box("url ", integer(1) + Data([1]))] {
            XCTAssertThrowsError(try SelfContainedMovie.validate(movie(reference: reference)))
        }
        XCTAssertThrowsError(try SelfContainedMovie.validate(Data("#EXTM3U\nhttps://example.test/movie.ts".utf8)))
        let externalMovie = box("ftyp", Data("qt  ".utf8) + integer(0)) + box("moov", box("rmra")) + box("mdat")
        XCTAssertThrowsError(try SelfContainedMovie.validate(externalMovie))
    }
    func testTruncatedOverflowingAndDeepContainersAreRejected() throws {
        let valid = movie(reference: box("url ", integer(1)))
        XCTAssertThrowsError(try SelfContainedMovie.validate(valid.dropLast()))
        XCTAssertThrowsError(try SelfContainedMovie.validate(integer(UInt32.max) + Data("ftypqt  ".utf8)))
        var body = box("dref", integer(0) + integer(1) + box("url ", integer(1)))
        for _ in 0..<14 { body = box("trak", body) }
        XCTAssertThrowsError(try SelfContainedMovie.validate(box("ftyp", Data("qt  ".utf8)+integer(0))+box("moov",body)+box("mdat")))
    }
}
