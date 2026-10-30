import Foundation
import XCTest
import SQLite3
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AVFoundation
import BBCClient
@testable import BBCMessagesActions

final class RichMessagingTests: XCTestCase {
    func testEmojiValidationPreservesComposedEmojiAndRejectsText() throws {
        for emoji in ["🎉", "👍🏽", "👩🏽‍💻", "🇳🇱", "1️⃣", "❤️", "👨‍👩‍👧‍👦"] {
            XCTAssertTrue(EmojiTapback.valid(emoji), emoji)
            let data = try JSONSerialization.data(withJSONObject: ["method": "tapback", "params": ["chat_guid": "any;-;fixture@example.test", "message_guid": UUID().uuidString, "reaction": emoji]])
            XCTAssertEqual(try JSONDecoder().decode(NativeRequest.self, from: data).validated().reaction, emoji)
        }
        for invalid in ["", "word", "1", "#", "🔥🔥", "🏽", "a\u{200d}", "\n"] { XCTAssertFalse(EmojiTapback.valid(invalid), invalid) }
        XCTAssertTrue(EmojiTapback.isDesired(current: "🎉", reaction: "🎉", remove: false))
        XCTAssertFalse(EmojiTapback.isDesired(current: "👍", reaction: "👍🏽", remove: false))
    }

    func testRichLinksDecodePlainAndKeyedPayloadWithoutInstantiatingClasses() throws {
        let metadata: [String: Any] = ["URL": ["NS.relative": "https://example.test/story"], "title": "A story", "summary": "Preview", "image": ["richLinkImageAttachmentSubstituteIndex": 0]]
        let plain = try PropertyListSerialization.data(fromPropertyList: ["richLinkMetadata": metadata], format: .binary, options: 0)
        let first = try XCTUnwrap(RichLinks.decode(plain, text: "", attachmentGUIDs: ["image-guid"]).first?.object)
        XCTAssertEqual(first["title"]?.string, "A story"); XCTAssertEqual(first["image_attachment_guid"]?.string, "image-guid")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: ["richLinkMetadata": metadata], requiringSecureCoding: false)
        XCTAssertEqual(RichLinks.decode(archived, text: "", attachmentGUIDs: [] ).first?.object?["url"]?.string, "https://example.test/story")
        let fallback = RichLinks.decode(Data("broken".utf8), text: "See https://example.test", attachmentGUIDs: [])
        XCTAssertEqual(fallback.first?.object?["preview"]?.bool, false)
        for value in ["file:///etc/passwd", "https://user:pass@example.test", "javascript:alert(1)", "https://example.test\n"] { XCTAssertNil(RichLinks.validURL(value)) }
        let cyclic: [String: Any] = ["$archiver": "NSKeyedArchiver", "$objects": [["CF$UID": 0]], "$top": ["root": ["CF$UID": 0]]]
        let cycle = try PropertyListSerialization.data(fromPropertyList: cyclic, format: .binary, options: 0)
        XCTAssertTrue(RichLinks.decode(cycle, text: "", attachmentGUIDs: []).isEmpty)
    }

    func testCustomReactionStateTracksOwnExactTargetAndRemoval() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var connection: OpaquePointer?; XCTAssertEqual(sqlite3_open(file.path, &connection), SQLITE_OK); defer { sqlite3_close(connection) }
        let guid = UUID().uuidString, chat = "any;-;fixture@example.test"
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TABLE message(service TEXT,is_from_me INTEGER,associated_message_type INTEGER,associated_message_guid TEXT,associated_message_emoji TEXT);
            CREATE TABLE chat(guid TEXT); CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            INSERT INTO chat VALUES('\(chat)');
            """, nil, nil, nil), SQLITE_OK)
        let database = try MessagesDatabase(url: file)
        func event(_ type: Int, _ emoji: String, own: Int = 1, part: Int = 0, reference: String? = nil) {
            let target = reference ?? "p:\(part)/\(guid)"
            XCTAssertEqual(sqlite3_exec(connection, "INSERT INTO message VALUES('iMessage',\(own),\(type),'\(target)','\(emoji)'); INSERT INTO chat_message_join VALUES(1,last_insert_rowid())", nil, nil, nil), SQLITE_OK)
        }
        event(2006, "👍🏽"); XCTAssertEqual(try database.reactionValue(chat: chat, message: guid), "👍🏽")
        event(2006, "🎉", own: 0); event(2006, "🔥", part: 1)
        XCTAssertEqual(try database.reactionValue(chat: chat, message: guid), "👍🏽")
        event(3006, "👍🏽"); XCTAssertNil(try database.reactionValue(chat: chat, message: guid))
        event(2001, ""); XCTAssertEqual(try database.reaction(chat: chat, message: guid), 1)
        for reference in [guid, "p:0/\(guid)", "bp:\(guid)", "p:0/bp:\(guid)"] {
            event(2006, "🎉", reference: reference)
            XCTAssertEqual(try database.reactionValue(chat: chat, message: guid), "🎉", reference)
            event(2006, "🔥", own: 0, reference: reference)
            XCTAssertEqual(try database.reactionValue(chat: chat, message: guid), "🎉", reference)
            event(3006, "🎉", reference: reference)
            XCTAssertNil(try database.reactionValue(chat: chat, message: guid), reference)
            XCTAssertEqual(database.normalizedGUID(reference), guid)
        }
        for reference in ["bp:garbage", "bp:bp:\(guid)", "p:-1/bp:\(guid)", "p:0/bp:\(guid)/extra", "p:0/", "bp:"] {
            XCTAssertNil(database.normalizedGUID(reference), reference)
        }
    }

    func testDownloadUsesExactAttachmentTupleAndBoundedChunksAndMediaReceiptIsExact() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent("Library/Messages/Attachments/fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = directory.appendingPathComponent("photo.png"), bytes = Data([0, 1, 2, 3, 4, 5])
        try bytes.write(to: file)
        let dbURL = home.appendingPathComponent("fixture.db")
        var connection: OpaquePointer?; XCTAssertEqual(sqlite3_open(dbURL.path, &connection), SQLITE_OK); defer { sqlite3_close(connection) }
        let guid = UUID().uuidString, chat = "any;-;fixture@example.test", uploadID = UUID()
        XCTAssertEqual(sqlite3_exec(connection, """
            CREATE TABLE message(guid TEXT,service TEXT,is_from_me INTEGER,is_sent INTEGER,error INTEGER);
            CREATE TABLE chat(guid TEXT,chat_identifier TEXT); CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            CREATE TABLE attachment(guid TEXT,filename TEXT,mime_type TEXT,total_bytes INTEGER,transfer_name TEXT);
            CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
            INSERT INTO chat VALUES('\(chat)','fixture@example.test'); INSERT INTO chat_handle_join VALUES(1,1);
            INSERT INTO message VALUES('\(guid)','iMessage',0,1,0); INSERT INTO chat_message_join VALUES(1,1);
            INSERT INTO attachment VALUES('attachment','\(file.path)','image/png',6,'\(uploadID.uuidString).png'); INSERT INTO message_attachment_join VALUES(1,1);
            """, nil, nil, nil), SQLITE_OK)
        let database = try MessagesDatabase(url: dbURL)
        let params: [String: BBCJSONValue] = ["chat_guid": .string(chat), "message_guid": .string(guid), "attachment_guid": .string("attachment"), "length": .number(3)]
        let first = try database.download(params, home: home)
        XCTAssertEqual(first.object?["data_base64"]?.string, Data([0, 1, 2]).base64EncodedString())
        XCTAssertEqual(first.object?["next_offset"]?.numberValue, 3); XCTAssertEqual(first.object?["complete"]?.bool, false)
        let last = try database.download(params.merging(["offset": .number(3)]) { _, new in new }, home: home)
        XCTAssertEqual(last.object?["data_base64"]?.string, Data([3, 4, 5]).base64EncodedString()); XCTAssertEqual(last.object?["complete"]?.bool, true)
        let invalidRequests: [[String: BBCJSONValue]] = [["attachment_guid": .string("other")], ["chat_guid": .string("any;-;other@example.test")], ["offset": .number(7)], ["length": .number(524289)]]
        for invalid in invalidRequests {
            XCTAssertThrowsError(try database.download(params.merging(invalid) { _, new in new }, home: home))
        }
        XCTAssertEqual(sqlite3_exec(connection, "ALTER TABLE attachment ADD COLUMN transfer_state INTEGER DEFAULT 5; ALTER TABLE attachment ADD COLUMN uti TEXT; UPDATE attachment SET total_bytes=7", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try database.download(params, home: home).object?["total_bytes"]?.numberValue, 6)
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE attachment SET transfer_state=3", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try database.download(params, home: home))
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE attachment SET transfer_state=5", nil, nil, nil), SQLITE_OK)
        let upload = MediaStore.Upload(id: uploadID, ext: "png", mimeType: "image/png", bytes: 6, created: Date())
        XCTAssertNil(try database.confirmedMedia(to: "fixture@example.test", upload: upload, after: 0))
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE message SET is_from_me=1", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try database.confirmedMedia(to: "fixture@example.test", upload: upload, after: 0)?.0, guid)
        XCTAssertNil(try database.confirmedMedia(to: "other@example.test", upload: upload, after: 0))
        XCTAssertNil(try database.confirmedMedia(to: "fixture@example.test", upload: upload, after: 1))
        // JSONEncoder may escape every slash in base64. Even worst-case binary
        // must fit both the worker and HTTP 2 MB response bounds.
        try Data(repeating: 255, count: 524288).write(to: file)
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE attachment SET total_bytes=524288", nil, nil, nil), SQLITE_OK)
        let worst = try database.download(params.merging(["length": .number(524288)]) { _, new in new }, home: home)
        XCTAssertLessThan(try JSONEncoder().encode(worst).count, 2_000_000)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: dbURL)
        XCTAssertThrowsError(try database.download(params, home: home))
    }

    static func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let data = NSMutableData(), image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    func testAudioAndVideoUploadsPreserveOriginalBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600; buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
        do { let writer = try AVAudioFile(forWriting: file, settings: format.settings); try writer.write(from: buffer) }
        let store = try MediaStore(directory: directory.appendingPathComponent("uploads"))
        let audio = try Data(contentsOf: file), upload = try await store.create(audio, filename: "clip.caf")
        XCTAssertEqual(try Data(contentsOf: store.resolve(upload.id.uuidString).1), audio)
        let video = try await movie(seconds: 1)
        let videoUpload = try await store.create(video, filename: "clip.mov")
        XCTAssertEqual(try Data(contentsOf: store.resolve(videoUpload.id.uuidString).1), video)
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
    func testPrivateHandoffIsBoundedReusableAndRejectsSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MediaStore(directory: root.appendingPathComponent("uploads"))
        let original = try Self.png()
        let upload = try await store.create(original, filename: "fixture.png")
        let source = try store.resolve(upload.id.uuidString).1
        let destination = root.appendingPathComponent("handoff")
        let file = try MediaStore.stageHandoff(upload: upload, source: source, directory: destination)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try MediaStore.stageHandoff(upload: upload, source: source, directory: destination), file)
        try MediaStore.removeHandoff(upload: upload, directory: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try MediaStore.stageHandoff(upload: upload, source: link, directory: destination))
        XCTAssertEqual(MediaMIME.resolve("", uti: "com.apple.coreaudio-format"), "audio/x-caf")
    }

    func testUploadsAreOpaqueValidatedPrivateAndExpire() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MediaStore(directory: directory), bytes = try Self.png()
        let upload = try await store.create(bytes, filename: "photo.png")
        let resolved = try store.resolve(upload.id.uuidString)
        XCTAssertEqual(try Data(contentsOf: resolved.1), bytes); XCTAssertEqual(upload.mimeType, "image/png")
        XCTAssertFalse(String(describing: upload.packet).contains(directory.path))
        XCTAssertThrowsError(try store.resolve("../photo.png"))
        do { _ = try await store.create(Data("not a photo".utf8), filename: "photo.png"); XCTFail("Invalid image accepted") } catch {}
        do { _ = try await store.create(bytes, filename: "photo.jpg"); XCTFail("Wrong content type accepted") } catch {}
        let expired = MediaStore.Upload(id: upload.id, ext: upload.ext, mimeType: upload.mimeType, bytes: upload.bytes, created: Date(timeIntervalSinceNow: -90000))
        try JSONEncoder().encode(expired).write(to: directory.appendingPathComponent(upload.id.uuidString + ".json"))
        XCTAssertThrowsError(try store.resolve(upload.id.uuidString))
        _ = try await store.create(bytes, filename: "new.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.1.path))
    }
}

@MainActor final class RichMessagingRouterTests: XCTestCase {
    func testUploadAuthenticationAndMediaAndLinkRoutesPreserveIdempotency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = try APIKeyStore(directory: directory), secret = try keys.create(name: "fixture")
        var methods: [String] = []
        let router = APIRouter(keys: keys) { payload in methods.append(payload.object?["method"]?.string ?? ""); return .object(["ok": .bool(true)]) }
        let bytes = try RichMessagingTests.png()
        let denied = await router.handle(method: "POST", path: "/v1/media/upload", headers: ["x-bbc-filename": "photo.png"], body: bytes)
        XCTAssertEqual(denied.status, 401)
        let headers = ["authorization": "Bearer " + secret, "x-bbc-filename": "photo.png"]
        let uploaded = await router.handle(method: "POST", path: "/v1/media/upload", headers: headers, body: bytes)
        XCTAssertEqual(uploaded.status, 201); XCTAssertNotNil(uploaded.value.object?["media_id"]?.string)
        let body = try JSONEncoder().encode(BBCJSONValue.object(["to": .string("fixture@example.test"), "media_id": uploaded.value.object!["media_id"]!]))
        let mutation = headers.merging(["idempotency-key": UUID().uuidString]) { _, new in new }
        _ = await router.handle(method: "POST", path: "/v1/messages", headers: mutation, body: body)
        _ = await router.handle(method: "POST", path: "/v1/messages", headers: mutation, body: body)
        _ = await router.handle(method: "POST", path: "/v1/media/download", headers: headers, body: Data("{}".utf8))
        _ = await router.handle(method: "POST", path: "/v1/links", headers: mutation.merging(["idempotency-key": UUID().uuidString]) { _, new in new }, body: Data("{}".utf8))
        XCTAssertEqual(methods, ["send", "media.download", "link"])
    }
}
