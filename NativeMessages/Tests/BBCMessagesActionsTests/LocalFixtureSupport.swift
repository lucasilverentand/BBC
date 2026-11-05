import Foundation
import XCTest
import AVFoundation
import CoreVideo
@testable import BBCMessagesActions

struct FixtureTimeout: Error, CustomStringConvertible { let description: String }

private final class ReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(returning: value)
    }
}

/// Starts a loopback listener on an ephemeral port with bounded readiness.
/// Returns the actual bound port. Failures stop the server and throw.
@MainActor func startFixtureServer(router: APIRouter, readiness: TimeInterval = 5) async throws -> (server: LocalAPIServer, port: UInt16, base: URL) {
    let server = try LocalAPIServer(host: "127.0.0.1", port: 0, router: router)
    let ready = await withCheckedContinuation { continuation in
        let gate = ReadyGate(continuation)
        server.start { gate.finish($0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + readiness) { gate.finish(false) }
    }
    guard ready, let port = server.boundPort, port != 0 else {
        server.stopAndDrain(); throw FixtureTimeout(description: "Loopback listener was not ready within \(readiness)s")
    }
    guard let base = URL(string: "http://127.0.0.1:\(port)") else { server.stopAndDrain(); throw URLError(.badURL) }
    return (server, port, base)
}

/// Writes a tiny synthetic movie. Every wait is bounded; setup problems throw.
func makeSyntheticMovie(seconds: Double, timeout: TimeInterval = 10) async throws -> Data {
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
    guard writer.canAdd(input) else { throw FixtureTimeout(description: "Writer rejected synthetic video input") }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? FixtureTimeout(description: "Writer failed to start") }
    writer.startSession(atSourceTime: .zero)
    let deadline = Date().addingTimeInterval(timeout)
    for time in [0.0, seconds / 2] {
        while !input.isReadyForMoreMediaData {
            guard Date() < deadline else { writer.cancelWriting(); throw FixtureTimeout(description: "Writer input never became ready") }
            try await Task.sleep(for: .milliseconds(5))
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
              let pixels = buffer else { writer.cancelWriting(); throw FixtureTimeout(description: "Pixel buffer unavailable") }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) { memset(base, 127, CVPixelBufferGetDataSize(pixels)) }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        guard adaptor.append(pixels, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else {
            writer.cancelWriting(); throw writer.error ?? FixtureTimeout(description: "Writer rejected frame")
        }
    }
    writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
    input.markAsFinished()
    let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let gate = ReadyGate(continuation)
        writer.finishWriting { gate.finish(true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.finish(false) }
    }
    guard finished else { writer.cancelWriting(); throw FixtureTimeout(description: "finishWriting exceeded \(timeout)s") }
    guard writer.status == .completed else { throw writer.error ?? FixtureTimeout(description: "Writer ended \(writer.status.rawValue)") }
    return try Data(contentsOf: file)
}
