import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
import BBCClient

/// Private, immutable uploads. API callers receive an opaque ID, never a path.
struct MediaStore {
    static let maximumBytes = 32 * 1024 * 1024
    static let lifetime: TimeInterval = 24 * 60 * 60
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blue Bubble Club/media")
    }
    let directory: URL
    init(directory: URL = defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard info[.type] as? FileAttributeType == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw ActionFailure.invalid }
    }
    struct Upload: Codable {
        let id: UUID
        let ext: String
        let mimeType: String
        let bytes: Int
        let created: Date
        var filename: String { id.uuidString + "." + ext }
        var packet: BBCJSONValue {
            .object(["media_id": .string(id.uuidString), "mime_type": .string(mimeType), "total_bytes": .number(Double(bytes)),
                     "expires_at": .string(ISO8601DateFormatter().string(from: created.addingTimeInterval(MediaStore.lifetime)))])
        }
    }
    func create(_ data: Data, filename: String) async throws -> Upload {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              filename.utf8.count <= 100, filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.unicodeScalars.contains(where: { $0.value < 32 }) else { throw ActionFailure.invalid }
        let ext = (filename as NSString).pathExtension.lowercased()
        let images = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff"]
        let movies = ["mp4", "mov", "m4v"]
        let audio = ["m4a", "mp3", "caf", "wav", "aif", "aiff", "aac"]
        let fallbackMIME = ["caf": "audio/x-caf", "aac": "audio/aac", "m4v": "video/mp4", "aif": "audio/aiff", "aiff": "audio/aiff", "wav": "audio/wav"]
        guard (images + movies + audio).contains(ext), let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? fallbackMIME[ext] else { throw ActionFailure.invalid }
        if audio.contains(ext), ext != "m4a" {
            let signature = Array(data.prefix(12))
            let valid: Bool
            switch ext {
            case "caf": valid = data.starts(with: Data("caff".utf8))
            case "wav": valid = data.starts(with: Data("RIFF".utf8)) && data.count >= 12 && Data(data[8..<12]) == Data("WAVE".utf8)
            case "aif", "aiff": valid = data.starts(with: Data("FORM".utf8)) && data.count >= 12 && ["AIFF", "AIFC"].contains(String(decoding: data[8..<12], as: UTF8.self))
            case "mp3": valid = data.starts(with: Data("ID3".utf8)) || (signature.count >= 2 && signature[0] == 0xff && signature[1] & 0xe0 == 0xe0)
            case "aac": valid = signature.count >= 2 && signature[0] == 0xff && signature[1] & 0xf6 == 0xf0
            default: valid = false
            }
            guard valid else { throw ActionFailure.invalid }
        }
        // Expired uploads and a fixed disk quota keep this local service bounded.
        var used = 0
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            guard let upload = try? JSONDecoder().decode(Upload.self, from: Data(contentsOf: file)) else { throw ActionFailure.unavailable }
            if Date().timeIntervalSince(upload.created) > Self.lifetime {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(upload.filename))
                try FileManager.default.removeItem(at: file)
            } else { used += upload.bytes }
        }
        guard used + data.count <= 512 * 1024 * 1024 else { throw ActionFailure.unavailable }
        let upload = Upload(id: UUID(), ext: ext, mimeType: mime, bytes: data.count, created: Date())
        let file = directory.appendingPathComponent(upload.filename)
        try data.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do {
            if images.contains(ext) {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      CGImageSourceGetCount(source) > 0,
                      let actual = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
                      actual.conforms(to: .image), actual == UTType(filenameExtension: ext) else { throw ActionFailure.invalid }
            } else {
                if ["mp4", "mov", "m4v", "m4a"].contains(ext) { try SelfContainedMovie.validate(data) }
                let asset = AVURLAsset(url: file)
                let tracks = try await asset.loadTracks(withMediaType: movies.contains(ext) ? .video : .audio)
                guard !tracks.isEmpty else { throw ActionFailure.invalid }
            }
            try JSONEncoder().encode(upload).write(to: directory.appendingPathComponent(upload.id.uuidString + ".json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(upload.id.uuidString + ".json").path)
            return upload
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    func resolve(_ raw: String) throws -> (Upload, URL) {
        guard let id = UUID(uuidString: raw) else { throw ActionFailure.invalid }
        let upload = try JSONDecoder().decode(Upload.self, from: Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json")))
        guard upload.id == id, Date().timeIntervalSince(upload.created) <= Self.lifetime,
              upload.ext.range(of: "^[a-z0-9]{2,5}$", options: .regularExpression) != nil else { throw ActionFailure.invalid }
        let file = directory.appendingPathComponent(upload.filename)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ActionFailure.invalid }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size == upload.bytes, info.st_size > 0, info.st_size <= Self.maximumBytes else { throw ActionFailure.invalid }
        return (upload, file)
    }
}

extension MessagesDatabase {
    func download(_ p: [String: BBCJSONValue], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> BBCJSONValue {
        guard let chat = p["chat_guid"]?.string, let message = p["message_guid"]?.string,
              let attachment = p["attachment_guid"]?.string, !attachment.isEmpty, attachment.utf8.count <= 256 else { throw ActionFailure.invalid }
        try verify(chat: chat, message: message)
        let offset = p["offset"]?.numberValue ?? 0, length = p["length"]?.numberValue ?? 524288
        guard offset.isFinite, offset >= 0, offset <= Double(MediaStore.maximumBytes), offset.rounded() == offset,
              length.isFinite, length >= 1, length <= 524288, length.rounded() == length else { throw ActionFailure.invalid }
        let values = try rows("""
            SELECT a.filename,COALESCE(a.mime_type,''),COALESCE(a.total_bytes,0)
            FROM attachment a JOIN message_attachment_join ma ON ma.attachment_id=a.ROWID
            JOIN message m ON m.ROWID=ma.message_id JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
            WHERE a.guid=?1 AND m.guid=?2 AND c.guid=?3 LIMIT 2
            """, [attachment, message, chat])
        guard values.count == 1, let row = values.first else { throw ActionFailure.invalid }
        let data = try AttachmentFile.read(row[0], home: home, maximumBytes: MediaStore.maximumBytes)
        guard (Int(row[2]) == 0 || Int(row[2]) == data.count), Int(offset) <= data.count else { throw ActionFailure.invalid }
        let end = min(data.count, Int(offset) + Int(length))
        return .object(["attachment_guid": .string(attachment), "mime_type": .string(row[1]), "total_bytes": .number(Double(data.count)),
                        "offset": .number(offset), "next_offset": .number(Double(end)), "complete": .bool(end == data.count),
                        "data_base64": .string(data[Int(offset)..<end].base64EncodedString())])
    }
    func confirmedMedia(to: String, upload: MediaStore.Upload, after: Int64) throws -> (String, String)? {
        let values = try rows("""
            SELECT DISTINCT m.guid,c.guid FROM message m JOIN chat_message_join cm ON cm.message_id=m.ROWID JOIN chat c ON c.ROWID=cm.chat_id
            JOIN message_attachment_join ma ON ma.message_id=m.ROWID JOIN attachment a ON a.ROWID=ma.attachment_id
            WHERE m.ROWID>CAST(?1 AS INTEGER) AND m.is_from_me=1 AND m.service='iMessage' AND m.is_sent=1 AND COALESCE(m.error,0)=0
            AND c.chat_identifier=?2 AND c.guid IN (?3,?4)
            AND a.transfer_name=?5 AND a.total_bytes=CAST(?6 AS INTEGER) LIMIT 2
            """, [String(after), to, "any;-;" + to, "iMessage;-;" + to, upload.filename, String(upload.bytes)])
        guard values.count <= 1 else { throw ActionFailure.uncertain }
        return values.first.map { ($0[0], $0[1]) }
    }
}
