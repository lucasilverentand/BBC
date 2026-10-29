import Darwin
import Foundation
import XCTest
import AVFoundation
@testable import BBCMessagesActions

final class LocalTranscriptionTests: XCTestCase, @unchecked Sendable {
    func testDurationAndSampleBoundsBeforeLoadingModels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        func audio(_ name: String, rate: Double, seconds: Double) throws -> URL {
            let url = directory.appendingPathComponent(name + ".caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let frames = AVAudioFrameCount(rate * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }
        XCTAssertEqual(try LocalTranscription.duration(of: audio("short", rate: 16000, seconds: 1)), 1, accuracy: 0.001)
        XCTAssertThrowsError(try LocalTranscription.duration(of: audio("long", rate: 16000, seconds: 180.1)))
        XCTAssertThrowsError(try LocalTranscription.duration(of: audio("rate", rate: 192000, seconds: 1)))
    }
    func testPreparedParakeetTranscribesSyntheticSpeechLocally() async throws {
        guard ProcessInfo.processInfo.environment["SEVEN_TEST_PREPARED_PARAKEET"] == "1" else {
            throw XCTSkip("Explicit operator-staged public model verification")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.aiff")
        let speech = Process(); speech.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speech.arguments = ["-o", file.path, "BBC audio test. BBCteen plus twenty five is forty two."]
        speech.standardOutput = FileHandle.nullDevice; speech.standardError = FileHandle.nullDevice
        try speech.run(); speech.waitUntilExit(); XCTAssertEqual(speech.terminationStatus, 0)
        let bytes = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
        // The runtime uses a fixed temporary basename; decoding must identify
        // the actual container from its contents rather than the suffix.
        let prepared = directory.appendingPathComponent("audio.caf")
        try FileManager.default.moveItem(at: file, to: prepared)
        let result = try await LocalTranscription.decode(prepared, inputBytes: bytes)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["local_processing"] as? Bool, true)
        XCTAssertEqual(result["model_revision"] as? String, LocalModels.revision)
        let text = (result["text"] as? String ?? "").lowercased()
        XCTAssertTrue(text.hasPrefix("bbc audio") || text.hasPrefix("7 audio"), "Synthetic fixture transcript: " + text)
        XCTAssertTrue(text.contains("bbcteen") || text.contains("17"), "Synthetic fixture transcript: " + text)
        XCTAssertTrue(text.contains("twenty five") || text.contains("25"), "Synthetic fixture transcript: " + text)
        XCTAssertTrue(text.contains("forty") || text.contains("42"), "Synthetic fixture transcript: " + text)
        XCTAssertGreaterThan(result["processing_seconds"] as? Double ?? 0, 0)
        XCTAssertLessThan(result["audio_seconds"] as? Double ?? 0, 180)
        XCTAssertNil(result["input_tokens"]); XCTAssertNil(result["output_tokens"])
    }
}
