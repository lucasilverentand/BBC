import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import AVFoundation

struct PreparedVisualFrame: Sendable {
    let jpeg: Data
    let width: Int
    let height: Int
    let seconds: Double?
}

struct PreparedVisualMedia: Sendable {
    let kind: String
    let inputBytes: Int
    let frames: [PreparedVisualFrame]
    let durationSeconds: Double?
    let coverage: String
    let audio: String

    // This is a bounded derivative for one explicit inspection, never ordinary
    // inbox context. Paths, filenames and original metadata do not leave the Mac.
    var packet: [String: Any] {
        var value: [String: Any] = ["ok": true, "kind": kind, "input_bytes": inputBytes,
            "coverage": coverage, "audio": audio, "local_preprocessing": true,
            "frames": frames.map { frame -> [String: Any] in
                var row: [String: Any] = ["mime_type": "image/jpeg", "width": frame.width,
                    "height": frame.height, "jpeg_base64": frame.jpeg.base64EncodedString()]
                if let seconds = frame.seconds { row["at_seconds"] = seconds }
                return row
            }]
        if let durationSeconds { value["duration_seconds"] = durationSeconds }
        return value
    }
}

enum LocalVisualMedia {
    static let maximumImageBytes = 16 * 1024 * 1024
    static let maximumVideoBytes = 32 * 1024 * 1024
    static let maximumFrameBytes = 128 * 1024
    static let maximumDimension = 1024
    static let maximumVideoSeconds = 60.0
    static let maximumFrames = 3

    static func prepare(_ attachment: VisualAttachment, home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> PreparedVisualMedia {
        let data = try AttachmentFile.read(attachment.filename, home: home, maximumBytes: attachment.maximumBytes)
        guard attachment.declaredBytes == 0 || attachment.declaredBytes == data.count else { throw ActionFailure.invalid }
        switch attachment.kind {
        case .image: return try image(data)
        case .video: return try await video(data)
        }
    }

    static func image(_ data: Data) throws -> PreparedVisualMedia {
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16384).contains(width), (1...16384).contains(height),
              width * height <= 100_000_000 else { throw ActionFailure.invalid }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ActionFailure.invalid
        }
        let frame = try encode(thumbnail)
        return .init(kind: "image", inputBytes: data.count, frames: [frame], durationSeconds: nil,
            coverage: CGImageSourceGetCount(source) == 1 ? "One resized image. Fine detail may be omitted."
                : "First image/frame only; animation and other pages were not inspected.",
            audio: "not applicable")
    }

    static func video(_ data: Data) async throws -> PreparedVisualMedia {
        guard !data.isEmpty, data.count <= maximumVideoBytes else { throw ActionFailure.invalid }
        try SelfContainedMovie.validate(data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BBCVisual-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.mov")
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let asset = AVURLAsset(url: file)
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0, seconds <= maximumVideoSeconds,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw ActionFailure.invalid }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var frames: [PreparedVisualFrame] = []
        for fraction in [0.1, 0.5, 0.9] {
            try Task.checkCancellation()
            let sample = try await generator.image(at: CMTime(seconds: seconds * fraction, preferredTimescale: 600))
            let actual = sample.actualTime.seconds
            guard actual.isFinite, actual >= 0, actual <= seconds + 0.1 else { throw ActionFailure.invalid }
            let frame = try encode(sample.image)
            frames.append(.init(jpeg: frame.jpeg, width: frame.width, height: frame.height, seconds: actual))
        }
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        return .init(kind: "video", inputBytes: data.count, frames: frames, durationSeconds: seconds,
            coverage: "Three sampled visual frames. Events between samples were not inspected. Audio was not transcribed.",
            audio: hasAudio ? "Audio track present but not transcribed; visual inspection only." : "No audio track.")
    }

    private static func encode(_ image: CGImage) throws -> PreparedVisualFrame {
        guard image.width > 0, image.height > 0, image.width <= maximumDimension,
              image.height <= maximumDimension else { throw ActionFailure.invalid }
        for limit in [maximumDimension, 768, 512] {
            let scale = min(1, Double(limit) / Double(max(image.width, image.height)))
            let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ActionFailure.unavailable
            }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let flattened = context.makeImage() else { throw ActionFailure.unavailable }
            for quality in [0.75, 0.5, 0.32] {
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw ActionFailure.unavailable
                }
                CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ActionFailure.invalid }
                if data.length <= maximumFrameBytes {
                    return .init(jpeg: data as Data, width: width, height: height, seconds: nil)
                }
            }
        }
        throw ActionFailure.invalid
    }
}
