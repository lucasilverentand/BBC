import Darwin
import Foundation
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
@testable import BBCMessagesActions

final class LocalVisualMediaTests: XCTestCase, @unchecked Sendable {
    private func bitmap(width: Int = 64, height: Int = 32) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func imageData(_ image: CGImage, type: UTType = .jpeg, count: Int = 1,
                           metadata: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, count, nil))
        for _ in 0..<count { CGImageDestinationAddImage(destination, image, metadata as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testImageIsResizedAndOriginalMetadataDoesNotReachDerivative() throws {
        let original = try imageData(bitmap(width: 2048, height: 1024), metadata: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 45.6, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "SYNTHETIC_PRIVATE_AUTHOR"]])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])
        let media = try LocalVisualMedia.image(original), frame = try XCTUnwrap(media.frames.first)
        XCTAssertEqual(media.frames.count, 1); XCTAssertEqual(media.kind, "image")
        XCTAssertEqual(frame.width, 1024); XCTAssertEqual(frame.height, 512)
        XCTAssertLessThanOrEqual(frame.jpeg.count, LocalVisualMedia.maximumFrameBytes)
        let derivative = try XCTUnwrap(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(derivative, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: media.packet), as: UTF8.self).contains("SYNTHETIC_PRIVATE_AUTHOR"))
    }
    func testSmallImagesAreNotUpscaledAndAnimatedCoverageIsExplicit() throws {
        let image = try bitmap()
        let small = try LocalVisualMedia.image(imageData(image))
        XCTAssertEqual(small.frames.first?.width, 64); XCTAssertEqual(small.frames.first?.height, 32)
        let animation = try LocalVisualMedia.image(imageData(image, type: .gif, count: 2))
        XCTAssertEqual(animation.frames.count, 1)
        XCTAssertTrue(animation.coverage.contains("First image/frame only"))
    }
    func testSelectedAttachmentReadChecksActualBytesAndNeverReturnsItsPath() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let attachments = home.appendingPathComponent("Library/Messages/Attachments/aa")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let data = try imageData(bitmap()), file = attachments.appendingPathComponent("PRIVATE_ORIGINAL_PHOTO.jpeg")
        try data.write(to: file)
        let target = VisualAttachment(filename: "~/Library/Messages/Attachments/aa/PRIVATE_ORIGINAL_PHOTO.jpeg", declaredBytes: Int64(data.count), kind: .image)
        let media = try await LocalVisualMedia.prepare(target, home: home)
        XCTAssertEqual(media.inputBytes, data.count)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: media.packet), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_ORIGINAL_PHOTO")); XCTAssertFalse(encoded.contains(home.path))
        let wrongSize = VisualAttachment(filename: target.filename, declaredBytes: Int64(data.count+1), kind: .image)
        do { _ = try await LocalVisualMedia.prepare(wrongSize, home: home); XCTFail("Changed attachment accepted") } catch {}
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: home.appendingPathComponent("outside.jpeg"))
        do { _ = try await LocalVisualMedia.prepare(target, home: home); XCTFail("Attachment symlink accepted") } catch {}
    }
    func testMalformedAndOversizeInputsAreRejected() async throws {
        for data in [Data(), Data("not an image".utf8), Data(repeating: 0, count: LocalVisualMedia.maximumImageBytes + 1)] {
            XCTAssertThrowsError(try LocalVisualMedia.image(data))
        }
        do { _ = try await LocalVisualMedia.video(Data("not a movie".utf8)); XCTFail("Malformed video accepted") }
        catch { /* No decoder fallback or external request. */ }
    }
    private func movie(seconds: Double) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.mov")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for time in [0.0, seconds / 2] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 127, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return try Data(contentsOf: file)
    }
    func testVideoUsesThreeBoundedSamplesAndDoesNotInventAudioOrContinuousCoverage() async throws {
        let media = try await LocalVisualMedia.video(movie(seconds: 2))
        XCTAssertEqual(media.kind, "video"); XCTAssertEqual(media.frames.count, 3)
        XCTAssertEqual(try XCTUnwrap(media.durationSeconds), 2, accuracy: 0.05)
        XCTAssertEqual(media.audio, "No audio track.")
        XCTAssertTrue(media.coverage.contains("Events between samples were not inspected"))
        for frame in media.frames {
            XCTAssertLessThanOrEqual(frame.jpeg.count, LocalVisualMedia.maximumFrameBytes)
            XCTAssertLessThanOrEqual(frame.width, LocalVisualMedia.maximumDimension)
            XCTAssertLessThanOrEqual(frame.height, LocalVisualMedia.maximumDimension)
            XCTAssertNotNil(frame.seconds)
        }
        let oversizedDuration = try await movie(seconds: 61)
        do { _ = try await LocalVisualMedia.video(oversizedDuration); XCTFail("Overlong movie accepted") }
        catch { /* Whole input is rejected, never silently truncated. */ }
    }
}
