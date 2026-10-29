import Foundation
import AVFoundation
import FluidAudio

enum LocalTranscription {
    static let maximumSeconds: Double = 180
    static let maximumCharacters = 12000

    static func duration(of file: URL) throws -> Double {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        guard (8000...96000).contains(format.sampleRate), (1...2).contains(format.channelCount), audio.length > 0 else { throw ActionFailure.invalid }
        let duration = Double(audio.length) / format.sampleRate
        guard duration.isFinite, duration > 0, duration <= maximumSeconds else { throw ActionFailure.invalid }
        return duration
    }
    static func transcribe(_ attachment: AudioAttachment) async throws -> [String: Any] {
        // Disable SDK transcript/debug output before any model or ASR object.
        AppLogger.minimumLevel = .fault; AppLogger.mirrorsToConsole = false
        let data = try AttachmentFile.read(attachment.filename)
        guard attachment.declaredBytes == 0 || attachment.declaredBytes == data.count else { throw ActionFailure.invalid }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BBCAudio-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = temporary.appendingPathComponent("audio.caf")
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try await decode(file, inputBytes: data.count)
    }
    // Internal seam for synthetic file/model verification. The stdio protocol
    // accepts only database-backed attachment IDs, never a file URL or path.
    static func decode(_ file: URL, inputBytes: Int) async throws -> [String: Any] {
        AppLogger.minimumLevel = .fault; AppLogger.mirrorsToConsole = false
        guard inputBytes > 0, inputBytes <= AttachmentFile.maximumBytes else { throw ActionFailure.invalid }
        let seconds = try duration(of: file)
        try LocalModels.verify(hashes: true)
        let start = Date()
        // loadLocal never resolves a model repository or performs a download.
        let models = try AsrModels.loadLocal(from: LocalModels.directory, version: .v3, encoderPrecision: .int8V2)
        let manager = AsrManager()
        try await manager.loadModels(models)
        var decoder = try TdtDecoderState()
        let result = try await manager.transcribe(file, decoderState: &decoder)
        guard result.text.count <= maximumCharacters else { throw ActionFailure.invalid }
        return ["ok": true, "text": result.text, "model": "parakeet-tdt-0.6b-v3",
                "model_revision": LocalModels.revision, "local_processing": true,
                "audio_seconds": seconds, "input_bytes": inputBytes,
                "processing_seconds": Date().timeIntervalSince(start), "coverage": "complete bounded attachment"]
    }
}
